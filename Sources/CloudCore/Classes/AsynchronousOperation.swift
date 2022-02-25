//
//  AsynchronousOperation.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 09.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import Foundation

/// Subclass of `Operation` that add support of asynchronous operations.
/// ## How to use:
/// 1. Call `super.main()` when override `main` method, call `super.start()` when override `start` method.
/// 2. When operation is finished or cancelled set `self.state = .finished`
public class AsynchronousOperation: Operation {
	open override var isAsynchronous: Bool { return true }
	open override var isExecuting: Bool { return state == .executing }
	open override var isFinished: Bool { return state == .finished }
	
	public var state = State.ready {
		willSet {
			willChangeValue(forKey: state.keyPath)
			willChangeValue(forKey: newValue.keyPath)
		}
		didSet {
			didChangeValue(forKey: state.keyPath)
			didChangeValue(forKey: oldValue.keyPath)
		}
	}
	
	public enum State: String {
		case ready = "Ready"
		case executing = "Executing"
		case finished = "Finished"
		fileprivate var keyPath: String { return "is" + self.rawValue }
	}
	
    override public func start() {
		if self.isCancelled {
			state = .finished
		} else {
			state = .ready
			main()
		}
	}
	
    override public func main() {
		if self.isCancelled {
			state = .finished
		} else {
			state = .executing
		}
	}
}
