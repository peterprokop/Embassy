//
//  SelectorEventLoop.swift
//  Embassy
//
//  Created by Fang-Pen Lin on 5/20/16.
//  Copyright © 2016 Fang-Pen Lin. All rights reserved.
//

import Foundation


private class CallbackHandle {
    let reader: (Void -> Void)?
    let writer: (Void -> Void)?
    init(reader: (Void -> Void)? = nil, writer: (Void -> Void)? = nil) {
        self.reader = reader
        self.writer = writer
    }
}

/// EventLoop uses given selector to monitor IO events, trigger callbacks when needed to
/// Follow Python EventLoop design https://docs.python.org/3/library/asyncio-eventloop.html
public final class SelectorEventLoop: EventLoopType {
    private(set) public var running: Bool = false
    private let selector: SelectorType
    // these are for self-pipe-trick ref: https://cr.yp.to/docs/selfpipe.html
    // to be able to interrupt the blocking selector, we create a pipe and add it to the
    // selector, whenever we want to interrupt the selector, we send a byte
    private let pipeSender: Int32
    private let pipeReceiver: Int32
    // callbacks ready to be called at the next iteration
    private var readyCallbacks = Atomic<[(Void -> Void)]>([])
    // callbacks scheduled to be called later
    private var scheduledCallbacks = Atomic<[(NSDate, (Void -> Void))]>([])

    public init(selector: SelectorType) throws {
        self.selector = selector
        var pipeFds = [Int32](count: 2, repeatedValue: 0)
        let pipeResult = pipeFds.withUnsafeMutableBufferPointer { pipe($0.baseAddress) }
        guard pipeResult >= 0 else {
            throw OSError.lastIOError()
        }
        pipeReceiver = pipeFds[0]
        pipeSender = pipeFds[1]
        IOUtils.setBlocking(pipeSender, blocking: false)
        IOUtils.setBlocking(pipeReceiver, blocking: false)
        // subscribe to pipe receiver read-ready event, do nothing, just allow selector
        // to be interrupted
        setReader(pipeReceiver) {}
    }

    deinit {
        stop()
        close(pipeSender)
        close(pipeReceiver)
    }

    public func setReader(fileDescriptor: Int32, callback: Void -> Void) {
        // we already have the file descriptor in selector, unregister it then register
        if let key = selector[fileDescriptor] {
            let oldHandle = key.data as! CallbackHandle
            let handle = CallbackHandle(reader: callback, writer: oldHandle.writer)
            try! selector.unregister(fileDescriptor)
            try! selector.register(fileDescriptor, events: key.events.union([.Read]), data: handle)
        // register the new file descriptor
        } else {
            try! selector.register(fileDescriptor, events: [.Read], data: CallbackHandle(reader: callback))
        }
    }

    public func removeReader(fileDescriptor: Int32) {
        guard let key = selector[fileDescriptor] else {
            return
        }
        try! selector.unregister(fileDescriptor)
        let newEvents = key.events.subtract([.Read])
        guard !newEvents.isEmpty else {
            return
        }
        let oldHandle = key.data as! CallbackHandle
        let handle = CallbackHandle(reader: nil, writer: oldHandle.writer)
        try! selector.register(fileDescriptor, events: newEvents, data: handle)
    }

    public func setWriter(fileDescriptor: Int32, callback: Void -> Void) {
        // we already have the file descriptor in selector, unregister it then register
        if let key = selector[fileDescriptor] {
            let oldHandle = key.data as! CallbackHandle
            let handle = CallbackHandle(reader: oldHandle.reader, writer: callback)
            try! selector.unregister(fileDescriptor)
            try! selector.register(fileDescriptor, events: key.events.union([.Write]), data: handle)
            // register the new file descriptor
        } else {
            try! selector.register(fileDescriptor, events: [.Write], data: CallbackHandle(writer: callback))
        }
    }

    public func removeWriter(fileDescriptor: Int32) {
        guard let key = selector[fileDescriptor] else {
            return
        }
        try! selector.unregister(fileDescriptor)
        let newEvents = key.events.subtract([.Write])
        guard !newEvents.isEmpty else {
            return
        }
        let oldHandle = key.data as! CallbackHandle
        let handle = CallbackHandle(reader: oldHandle.reader, writer: nil)
        try! selector.register(fileDescriptor, events: newEvents, data: handle)
    }

    public func callSoon(callback: Void -> Void) {
        readyCallbacks.modify { callbacks in
            var callbacks = callbacks
            callbacks.append(callback)
            return callbacks
        }
        interruptSelector()
    }

    public func callLater(delay: NSTimeInterval, callback: Void -> Void) {
        callAt(NSDate().dateByAddingTimeInterval(delay), callback: callback)
    }

    public func callAt(time: NSDate, callback: Void -> Void) {
        scheduledCallbacks.modify { callbacks in
            var callbacks = callbacks
            HeapSort.heapPush(&callbacks, item: (time, callback)) { $0.0.0.timeIntervalSince1970 < $0.1.0.timeIntervalSince1970 }
            return callbacks
        }
        interruptSelector()
    }

    public func stop() {
        running = false
        interruptSelector()
    }

    public func runForever() {
        running = true
        while running {
            runOnce()
        }
    }

    // interrupt the selector
    private func interruptSelector() {
        let byte = [UInt8](count: 1, repeatedValue: 0)
        assert(write(pipeSender, byte, byte.count) >= 0, "Failed to interrupt selector, errno=\(errno), message=\(lastErrorDescription())")
    }

    // Run once iteration for the event loop
    private func runOnce() {
        var timeout: NSTimeInterval?
        scheduledCallbacks.withValue { callbacks in
            // as the scheduledCallbacks is a heap queue, the first one will be the smallest one (the latest one)
            if let firstTuple = callbacks.first {
                // schedule timeout for the very next scheduled callback
                let (minTime, _) = firstTuple
                timeout = max(0, NSDate().timeIntervalSinceDate(minTime))
            } else {
                timeout = nil
            }
        }

        var events: [(SelectorKey, Set<IOEvent>)] = []
        // Poll IO events
        do {
            events = try selector.select(timeout)
        } catch OSError.IOError(let number, let message) {
            assert(Int32(number) == EINTR, "Failed to call selector, errno=\(number), message=\(message)")
        } catch {
            fatalError("Failed to call selector, errno=\(errno), message=\(lastErrorDescription())")
        }
        for (key, ioEvents) in events {
            guard let handle = key.data as? CallbackHandle else {
                continue
            }
            for ioEvent in ioEvents {
                switch ioEvent {
                case .Read:
                    if let callback = handle.reader {
                        callback()
                    }
                case .Write:
                    if let callback = handle.writer {
                        callback()
                    }
                }
            }
        }

        // Call scheduled callbacks
        let now = NSDate()
        var readyScheduledCallbacks: [(Void -> Void)] = []
        scheduledCallbacks.modify { callbacks in
            var notExpiredCallbacks = callbacks
            // keep poping expired callbacks
            let timestamp = now.timeIntervalSince1970
            while !notExpiredCallbacks.isEmpty && timestamp >= notExpiredCallbacks.first!.0.timeIntervalSince1970  {
                // pop the expired callbacks from heap queue and add them to ready callback list
                let (_, callback) = HeapSort.heapPop(&notExpiredCallbacks) { $0.0.0.timeIntervalSince1970 < $0.1.0.timeIntervalSince1970 }
                readyScheduledCallbacks.append(callback)
            }
            return notExpiredCallbacks
        }

        // Call ready callbacks
        let callbacks = readyCallbacks.swap([]) + readyScheduledCallbacks
        for callback in callbacks {
            callback()
        }
    }

}
