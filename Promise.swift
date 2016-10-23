//
//  Promise.swift
//
//  Created by Til Schneider <github@murfman.de> on 01.12.15.
//  Copyright © 2015 Junghans und Schneider. License: MIT
//  https://github.com/junghans-schneider/Promise4Swift
//

import Foundation

private enum PromiseState {
    case pending, succeed, failed, cancelled
}

private class WeakCancellable {
    weak var value : Cancellable?
    init (value: Cancellable) {
        self.value = value
    }
}

private protocol Cancellable: AnyObject {
    var isFinished: Bool { get }
    @discardableResult func cancel(wholeChain: Bool) -> Bool
}


/**
    Resolves or rejects its corresponding promise.

    This seperates the promise part from the resolver part. So:

    - You can give the promise to any number of consumers and all of them will observe the resolution independently. Because the capability of observing
      a promise is separated from the capability of resolving the promise, none of the recipients of the promise have the ability to "trick" other
      recipients with misinformation (or indeed interfere with them in any way).

    - You can give the resolver to any number of producers and whoever resolves the promise first wins. Furthermore, none of the producers can observe
      that they lost unless you give them the promise part too.

    - Author: Til Schneider <github@murfman.de>
*/
open class Deferred<ValueType> {

    /// The corresponding promise.
    open var promise = Promise<ValueType>()


    /**
        Resolves the corresponding promise.

        - Parameter value: The value to use for finishing the promise.
    */
    open func resolve(_ value: ValueType) {
        promise.resolve(value)
    }

    /**
        Resolves the corresponding promise.

        - Parameter nestedPromise: The promise to use for finishing the corresponding promise: The corresponding promise finishes whenever the nested promise
          finishes using the same result.
    */
    open func resolve(_ nestedPromise: Promise<ValueType>) {
        promise.resolve(nestedPromise)
    }

    /**
        Rejects the corresponding promise.

        - Parameter error: The error to use for finishing the promise.
    */
    open func reject(_ error: Any) {
        promise.reject(error)
    }

    /// Creates a new deferred.
    public init() {
    }
}


/// The error handler to call if a promise fails without having an error handler.
public var PromiseFallbackErrorHandler: ((_ error: Any) -> Void)? = nil


/**
    A `Promise` represents the result of an asynchrounous task, which may or may not have completed.

    Promises help avoiding the "Pyramid of Doom": the situation where code marches to the right faster than it marches forward.

    ~~~
    step1 { value1 in
        step2 { value2 in
            step3 { value3 in
                step4 { value4 in
                    // Do something with value4
                }
            }
        }
    }
    ~~~

    With promises, you can flatten the pyramid.

    ~~~
    step1
        .then(step2)
        .then(step3)
        .then(step4)
        .onValue { value4 in
            // Do something with value4
        }
        .onError { error in
            // Handle any error from all above steps
        }
        .onFinally {
            // Do something after the task-chain has finished
            // (no matter if it succeed or had an error)
        }
    ~~~

    The API is inspired by [Q promises](https://github.com/kriskowal/q). Missing compared to Q promises: `allSettled`, `progress`

    - Author: Til Schneider <github@murfman.de>
*/
open class Promise<ValueType>: Cancellable {

    public typealias ValueHandler = (_ value: ValueType) -> Void
    public typealias ErrorHandler = (_ error: Any) -> Void
    public typealias SimpleHandler = () -> Void


    fileprivate var mState: PromiseState = .pending

    /// Whether the promise has finished (so it's either successfull, failed or cancelled).
    open var isFinished: Bool {
        get {
            return mState == .succeed || mState == .failed || mState == .cancelled
        }
    }

    /// Whether the promise has finished successfully.
    open var isSuccessfull: Bool {
        get {
            return mState == .succeed
        }
    }

    /// Whether the promise has finished with an error.
    open var isFailed: Bool {
        get {
            return mState == .failed
        }
    }

    /// Whether the promise was cancelled (before it has finished).
    open var isCancelled: Bool {
        get {
            return mState == .cancelled
        }
    }

    /**
        Whether this promises can be cancelled. Defaults to `true`.
        You should set this to `false` if you share a promise instance for multiple consumers. So it can't be cancelled by one consumer while another consumer
        waits for the result.
    */
    open var cancellable = true

    fileprivate var mValue: ValueType? = nil
    fileprivate var mError: Any? = nil

    fileprivate var mAncestorPromises: [WeakCancellable]? = nil

    fileprivate var mHandlerQueuesClosed = false
    fileprivate var mValueHandlers:   [ValueHandler]? = nil
    fileprivate var mErrorHandlers:   [ErrorHandler]? = nil
    fileprivate var mCancelHandlers:  [SimpleHandler]? = nil
    fileprivate var mFinallyHandlers: [SimpleHandler]? = nil


    fileprivate init() {
    }

    /**
        Creates a resolved promise.

        If you want to create a promise for resolving (or rejecting) later, use `Deferred`.

        - Parameter value: The value to use for resolving the promise.
    */
    public init(value: ValueType) {
        resolve(value)
    }


    /**
        Chains a promise to this promise.

        - Parameter onValue: The closure to call after this promise has a value. The closure gets the value of this promise and a `Deferred` for resolving
          the chained promise.
        - Returns: The chained promise for the closure's result.
    */
    open func then<ChildValueType>(_ onValue: @escaping (_ value: ValueType, _ deferred: Deferred<ChildValueType>) -> Void) -> Promise<ChildValueType> {
        let wrapperHandler = WrapperHandler<ValueType, ChildValueType>(nestedOnValue: onValue)
        let childPromise = wrapperHandler.deferred.promise
        childPromise.addAncestor(self)

        handle(onValue: wrapperHandler.onValue, onError: wrapperHandler.onError, onCancel: wrapperHandler.onCancel, ensureAsyncCalls: true)

        return childPromise
    }

    /**
        Chains a promise to this promise.

        - Parameter resultType: The type of the chained promise's value (for setting an explicite type).
        - Parameter onValue: The closure to call after this promise has a value. The closure gets the value of this promise and a `Deferred` for resolving
          the chained promise.
        - Returns: The chained promise for the closure's result.
    */
    open func then<ChildValueType>(resultType: ChildValueType.Type, onValue: @escaping (_ value: ValueType, _ deferred: Deferred<ChildValueType>) -> Void)
        -> Promise<ChildValueType>
    {
        return then(onValue)
    }

    /**
        Chains a promise to this promise.

        - Parameter onValue: The closure to call after this promise has a value. The closure gets the value and returns a promise which will be used for
          resolving the chained promise.
        - Returns: The chained promise for the closure's result.
    */
    open func then<ChildValueType>(_ onValue: @escaping (_ value: ValueType) -> Promise<ChildValueType>) -> Promise<ChildValueType> {
        return then({ (value, deferred) -> Void in
            let nestedPromise = onValue(value)
            deferred.resolve(nestedPromise)
        })
    }

    /**
        Adds a handler to call if the promise has finished successfully.
        If the promise is already successful, the handler will also be called (but asynchronously).

        - Parameter onValue: The success handler
        - Returns: `self` (to use for method chaining)
    */
    @discardableResult open func onValue(_ onValue: @escaping ValueHandler) -> Promise<ValueType> {
        handle(onValue: onValue, ensureAsyncCalls: true)
        return self
    }

    /**
        Adds a handler to call if the promise has finished with an error.
        If the promise has already failed, the handler will also be called (but asynchronously).

        - Parameter onError: The error handler
        - Returns: `self` (to use for method chaining)
    */
    @discardableResult open func onError(_ onError: @escaping ErrorHandler) -> Promise<ValueType> {
        handle(onError: onError, ensureAsyncCalls: true)
        return self
    }

    /**
        Adds a handler to call if the promise was cancelled.
        If the promise is already cancelled, the handler will also be called (but asynchronously).

        - Parameter onCancel: The cancel handler
        - Returns: `self` (to use for method chaining)
    */
    @discardableResult open func onCancel(_ onCancel: @escaping SimpleHandler) -> Promise {
        handle(onCancel: onCancel, ensureAsyncCalls: true)
        return self
    }

    /**
        Adds a handler to call if the promise has finished (either successfully, failed or cancelled).
        If the promise is already finished, the handler will also be called (but asynchronously).

        - Parameter onFinally: The finally handler
        - Returns: `self` (to use for method chaining)
    */
    @discardableResult open func onFinally(_ onFinally: @escaping SimpleHandler) -> Promise {
        handle(onFinally: onFinally, ensureAsyncCalls: true)
        return self
    }

    fileprivate func handle(onValue: ValueHandler? = nil, onError: ErrorHandler? = nil, onCancel: SimpleHandler? = nil,
        onFinally: SimpleHandler? = nil, ensureAsyncCalls: Bool)
    {
        if mHandlerQueuesClosed {
            if ensureAsyncCalls {
                PromiseUtil.scheduleTimer() { () in
                    self.handle(onValue: onValue, onError: onError, onCancel: onCancel, ensureAsyncCalls: false)
                }
            } else {
                switch mState {
                case .succeed:
                    if let onValue = onValue {
                        onValue(mValue!)
                    }
                case .failed:
                    if let onError = onError {
                        onError(error: mError!)
                    }
                case .cancelled:
                    if let onCancel = onCancel {
                        onCancel()
                    }
                default:
                    print("WARNING: Expected finished state, not \(mState)")
                    return
                }

                if let onFinally = onFinally {
                    onFinally()
                }
            }
        } else {
            if let onValue = onValue {
                if self.mValueHandlers == nil {
                    self.mValueHandlers = [ onValue ]
                } else {
                    self.mValueHandlers!.append(onValue)
                }
            }
            if let onError = onError {
                if self.mErrorHandlers == nil {
                    self.mErrorHandlers = [ onError ]
                } else {
                    self.mErrorHandlers!.append(onError)
                }
            }
            if let onCancel = onCancel {
                if self.mCancelHandlers == nil {
                    self.mCancelHandlers = [ onCancel ]
                } else {
                    self.mCancelHandlers!.append(onCancel)
                }
            }
            if let onFinally = onFinally {
                if self.mFinallyHandlers == nil {
                    self.mFinallyHandlers = [ onFinally ]
                } else {
                    self.mFinallyHandlers!.append(onFinally)
                }
            }
        }
    }

    /**
        Tries to cancel the promise.

        - Parameter wholeChain: If `true` all parent promises will be cancelled as well
        - Returns: Whether the promise could be cancelled (= whether `cancellable` is `true` and it the promise hasn't finished before)
    */
    @discardableResult open func cancel(wholeChain: Bool = false) -> Bool {
        if isCancelled {
            return true
        } else if !cancellable || isFinished {
            return false
        } else {
            // TODO (maybe): Don't cancel promises having other uncancelled child promises.
            mState = .cancelled

            if wholeChain {
                if let ancestorPromises = self.mAncestorPromises {
                    for weakPromise in ancestorPromises {
                        if let promise = weakPromise.value {
                            promise.cancel(wholeChain: true)
                        }
                    }
                }
            }
            self.mAncestorPromises = nil

            fireFinished();

            return true;
        }
    }

    fileprivate func addAncestor(_ ancestor: Cancellable) {
        if ancestor.isFinished {
            return
        }

        let weakAncestor = WeakCancellable(value: ancestor)
        if self.mAncestorPromises == nil {
            self.mAncestorPromises = [ weakAncestor ]
        } else {
            self.mAncestorPromises!.append(weakAncestor)
        }
    }

    fileprivate func resolve(_ value: ValueType) {
        if isFinished {
            return
        }

        self.mValue = value
        mState = .succeed
        fireFinished()
    }

    fileprivate func resolve(_ nestedPromise: Promise<ValueType>) {
        if isFinished {
            return
        }

        addAncestor(nestedPromise)
        nestedPromise.handle(
            onValue: { value in
                self.resolve(value)
            },
            onError: { error in
                self.reject(error)
            },
            onCancel: {
                self.cancel()
            },
            ensureAsyncCalls: false)
    }

    fileprivate func reject(_ error: Any) {
        if isFinished {
            print("ERROR: Caught error after promise was finished: \(error)")
        } else {
            self.mError = error
            mState = .failed
            fireFinished()
        }
    }

    fileprivate func fireFinished(retryAsyncAllowed: Bool = true) {
        if !Thread.isMainThread {
            fatalError("Promise was finished outside the main thread")
        }
        if !isFinished {
            fatalError("fireFinished was called on a non-finished promise")
        }
        if mHandlerQueuesClosed {
            fatalError("fireFinished was called after the handler queues were already closed")
        }

        if retryAsyncAllowed {
            let hasHandlers = (mValueHandlers != nil) || (mErrorHandlers != nil) || (mCancelHandlers != nil) || (mFinallyHandlers != nil)
            if !hasHandlers {
                // There were no handlers added yet - maybe this promise was resolved synchronously
                // -> Try again asynchronously
                PromiseUtil.scheduleTimer() { () in
                    self.fireFinished(retryAsyncAllowed: false)
                }
                return
            }
        }

        // NOTE: We finish our promise after the current promise has called all of its handlers in order to ensure that all promises are finished one after the other
        if PromiseUtil.isPromiseHandlerFlushRunning {
            PromiseUtil.executeOutsidePromiseHandlerFlush {
                self.fireFinished(retryAsyncAllowed: retryAsyncAllowed)
            }
            return
        }

        PromiseUtil.onPromiseHandlerFlushStart()

        mHandlerQueuesClosed = true

        switch mState {
        case .succeed:
            if let valueHandlers = self.mValueHandlers {
                for onValue in valueHandlers {
                    onValue(mValue!)
                }
            }
        case .failed:
            if let errorHandlers = self.mErrorHandlers {
                for onError in errorHandlers {
                    onError(error: mError!)
                }
            } else if let fallbackHandler = PromiseFallbackErrorHandler {
                fallbackHandler(error: mError!)
            } else {
                print("ERROR: Promise caused error: \(mError!)")
            }
        case .cancelled:
            if let cancelHandlers = self.mCancelHandlers {
                for onCancel in cancelHandlers {
                    onCancel()
                }
            }
        default:
            print("ERROR: Expected finished state, not \(mState)")
        }

        if let finallyHandlers = self.mFinallyHandlers {
            for onFinally in finallyHandlers {
                onFinally()
            }
        }

        self.mAncestorPromises = nil
        self.mValueHandlers    = nil
        self.mErrorHandlers    = nil
        self.mCancelHandlers   = nil
        self.mFinallyHandlers  = nil

        PromiseUtil.onPromiseHandlerFlushEnd()
    }
}


/**
    Utilities for promises.

    - Author: Til Schneider <github@murfman.de>
*/
open class PromiseUtil {

    fileprivate static var isPromiseHandlerFlushRunning = false
    fileprivate static var pendingPromiseHandlerFlushHandlers: [() -> Void] = []


    fileprivate static func onPromiseHandlerFlushStart() {
        if isPromiseHandlerFlushRunning {
            print("WARNING: onPromiseHandlerFlushStart called while flush is already running")
        }

        isPromiseHandlerFlushRunning = true
    }

    fileprivate static func onPromiseHandlerFlushEnd() {
        if !isPromiseHandlerFlushRunning {
            print("WARNING: onPromiseHandlerFlushEnd called, but flush wasn't running")
        }

        isPromiseHandlerFlushRunning = false

        while !pendingPromiseHandlerFlushHandlers.isEmpty {
            if isPromiseHandlerFlushRunning {
                break
            } else {
                let firstHandler = pendingPromiseHandlerFlushHandlers.removeFirst()
                firstHandler()
            }
        }
    }

    fileprivate static func executeOutsidePromiseHandlerFlush(_ handler: @escaping () -> Void) {
        if !isPromiseHandlerFlushRunning {
            handler()
        } else {
            pendingPromiseHandlerFlushHandlers.append(handler)
        }
    }

    /**
        Creates a resolved (= successful) promise.

        - Parameter value: The promise's value
        - Returns: A promise which finished with `value`
    */
    open static func resolvedPromise<ValueType>(_ value: ValueType) -> Promise<ValueType> {
        let promise = Promise<ValueType>()
        promise.resolve(value)
        return promise
    }

    /**
        Creates a resolved (= successful) promise.

        - Parameter value: The promise's value
        - Parameter valueType: The value type (for setting an explicite type)
        - Returns: A promise which finished with `value`
    */
    open static func resolvedPromise<ValueType>(_ value: ValueType, valueType: ValueType.Type) -> Promise<ValueType> {
        return resolvedPromise(value)
    }

    /**
        Creates a rejected (= failed) promise.

        - Parameter error: The error
        - Returns: A promise which failed with `error`
    */
    open static func rejectedPromise<ValueType>(_ error: Any) -> Promise<ValueType> {
        let promise = Promise<ValueType>()
        promise.reject(error)
        return promise
    }

    /**
        Creates a rejected (= failed) promise.

        - Parameter error: The error
        - Parameter valueType: The value type (for setting an explicite type)
        - Returns: A promise which failed with `error`
    */
    open static func rejectedPromise<ValueType>(_ error: Any, valueType: ValueType.Type) -> Promise<ValueType> {
        return rejectedPromise(error)
    }

    /**
        Creates a promise waiting for two parallel promises.

        - Parameter promise1: Promise #1
        - Parameter promise2: Promise #2
        - Returns: A promise finishing after all promises have finished. The values of the promises are passed in a tupel.
    */
    open static func all<Type1, Type2>(_ promise1: Promise<Type1>, _ promise2: Promise<Type2>) -> Promise<(Type1, Type2)> {
        // Doesn't work since Xcode 7.3 (see below in class ParallelPromiseGroup)
        //return ParallelPromiseGroup()
        //    .addPromise(promise1)
        //    .addPromise(promise2)
        //    .allSettled()
        //    .then { (valueArray, deferred: Deferred<(Type1, Type2)>) in
        //        deferred.resolve((valueArray[0] as! Type1, valueArray[1] as! Type2))

        // Since Xcode 7.3 we have to go the long way...
        var value1: Type1? = nil;
        var value2: Type2? = nil;
        var pendingCount = 2;
        let deferred = Deferred<(Type1, Type2)>()

        func onOneValueSet() {
            pendingCount -= 1;
            if pendingCount == 0 {
                deferred.resolve((value1!, value2!))
            }
        }

        promise1
            .onValue { value in
                value1 = value
                onOneValueSet()
            }
            .onError { error in
                deferred.reject(error)
            }
            .onCancel {
                deferred.promise.cancel()
            }

        promise2
            .onValue { value in
                value2 = value
                onOneValueSet()
            }
            .onError { error in
                deferred.reject(error)
            }
            .onCancel {
                deferred.promise.cancel()
            }

        return deferred.promise;
    }

    /**
        Creates a promise waiting for three parallel promises.

        - Parameter promise1: Promise #1
        - Parameter promise2: Promise #2
        - Parameter promise3: Promise #3
        - Returns: A promise finishing after all promises have finished. The values of the promises are passed in a tupel.
    */
    open static func all<Type1, Type2, Type3>(_ promise1: Promise<Type1>, _ promise2: Promise<Type2>, _ promise3: Promise<Type3>)
        -> Promise<(Type1, Type2, Type3)>
    {
        // Doesn't work since Xcode 7.3 (see below in class ParallelPromiseGroup)
        //return ParallelPromiseGroup()
        //    .addPromise(promise1)
        //    .addPromise(promise2)
        //    .addPromise(promise3)
        //    .allSettled()
        //    .then { (valueArray, deferred: Deferred<(Type1, Type2, Type3)>) in
        //        deferred.resolve((valueArray[0] as! Type1, valueArray[1] as! Type2, valueArray[2] as! Type3))
        //    }

        // Since Xcode 7.3 we have to go the long way...
        var value1: Type1? = nil;
        var value2: Type2? = nil;
        var value3: Type3? = nil;
        var pendingCount = 3;
        let deferred = Deferred<(Type1, Type2, Type3)>()

        func onOneValueSet() {
            pendingCount -= 1;
            if pendingCount == 0 {
                deferred.resolve((value1!, value2!, value3!))
            }
        }

        promise1
            .onValue { value in
                value1 = value
                onOneValueSet()
            }
            .onError { error in
                deferred.reject(error)
            }
            .onCancel {
                deferred.promise.cancel()
            }

        promise2
            .onValue { value in
                value2 = value
                onOneValueSet()
            }
            .onError { error in
                deferred.reject(error)
            }
            .onCancel {
                deferred.promise.cancel()
            }

        promise3
            .onValue { value in
                value3 = value
                onOneValueSet()
            }
            .onError { error in
                deferred.reject(error)
            }
            .onCancel {
                deferred.promise.cancel()
            }

        return deferred.promise;
    }

    /**
        Creates a promise waiting for four parallel promises.

        - Parameter promise1: Promise #1
        - Parameter promise2: Promise #2
        - Parameter promise3: Promise #3
        - Parameter promise4: Promise #4
        - Returns: A promise finishing after all promises have finished. The values of the promises are passed in a tupel.
    */
    open static func all<Type1, Type2, Type3, Type4>(_ promise1: Promise<Type1>, _ promise2: Promise<Type2>, _ promise3: Promise<Type3>,
        _ promise4: Promise<Type4>) -> Promise<(Type1, Type2, Type3, Type4)>
    {
        // Doesn't work since Xcode 7.3 (see below in class ParallelPromiseGroup)
        //return ParallelPromiseGroup()
        //    .addPromise(promise1)
        //    .addPromise(promise2)
        //    .addPromise(promise3)
        //    .addPromise(promise4)
        //    .allSettled()
        //    .then { (valueArray, deferred: Deferred<(Type1, Type2, Type3, Type4)>) in
        //        deferred.resolve((valueArray[0] as! Type1, valueArray[1] as! Type2, valueArray[2] as! Type3, valueArray[3] as! Type4))
        //}

        // Since Xcode 7.3 we have to go the long way...
        var value1: Type1? = nil;
        var value2: Type2? = nil;
        var value3: Type3? = nil;
        var value4: Type4? = nil;
        var pendingCount = 4;
        let deferred = Deferred<(Type1, Type2, Type3, Type4)>()

        func onOneValueSet() {
            pendingCount -= 1;
            if pendingCount == 0 {
                deferred.resolve((value1!, value2!, value3!, value4!))
            }
        }

        promise1
            .onValue { value in
                value1 = value
                onOneValueSet()
            }
            .onError { error in
                deferred.reject(error)
            }
            .onCancel {
                deferred.promise.cancel()
            }

        promise2
            .onValue { value in
                value2 = value
                onOneValueSet()
            }
            .onError { error in
                deferred.reject(error)
            }
            .onCancel {
                deferred.promise.cancel()
            }

        promise3
            .onValue { value in
                value3 = value
                onOneValueSet()
            }
            .onError { error in
                deferred.reject(error)
            }
            .onCancel {
                deferred.promise.cancel()
            }

        promise4
            .onValue { value in
                value4 = value
                onOneValueSet()
            }
            .onError { error in
                deferred.reject(error)
            }
            .onCancel {
                deferred.promise.cancel()
            }

        return deferred.promise;
    }

    /**
        Creates a promise waiting for five parallel promises.

        - Parameter promise1: Promise #1
        - Parameter promise2: Promise #2
        - Parameter promise3: Promise #3
        - Parameter promise4: Promise #4
        - Parameter promise5: Promise #5
        - Returns: A promise finishing after all promises have finished. The values of the promises are passed in a tupel.
    */
    open static func all<Type1, Type2, Type3, Type4, Type5>(_ promise1: Promise<Type1>, _ promise2: Promise<Type2>, _ promise3: Promise<Type3>,
        _ promise4: Promise<Type4>, _ promise5: Promise<Type5>) -> Promise<(Type1, Type2, Type3, Type4, Type5)>
    {
        // Doesn't work since Xcode 7.3 (see below in class ParallelPromiseGroup)
        //return ParallelPromiseGroup()
        //    .addPromise(promise1)
        //    .addPromise(promise2)
        //    .addPromise(promise3)
        //    .addPromise(promise4)
        //    .addPromise(promise5)
        //    .allSettled()
        //    .then { (valueArray, deferred: Deferred<(Type1, Type2, Type3, Type4, Type5)>) in
        //        deferred.resolve((valueArray[0] as! Type1, valueArray[1] as! Type2, valueArray[2] as! Type3, valueArray[3] as! Type4, valueArray[4] as! Type5))
        //}

        // Since Xcode 7.3 we have to go the long way...
        var value1: Type1? = nil;
        var value2: Type2? = nil;
        var value3: Type3? = nil;
        var value4: Type4? = nil;
        var value5: Type5? = nil;
        var pendingCount = 5;
        let deferred = Deferred<(Type1, Type2, Type3, Type4, Type5)>()

        func onOneValueSet() {
            pendingCount -= 1;
            if pendingCount == 0 {
                deferred.resolve((value1!, value2!, value3!, value4!, value5!))
            }
        }

        promise1
            .onValue { value in
                value1 = value
                onOneValueSet()
            }
            .onError { error in
                deferred.reject(error)
            }
            .onCancel {
                deferred.promise.cancel()
            }

        promise2
            .onValue { value in
                value2 = value
                onOneValueSet()
            }
            .onError { error in
                deferred.reject(error)
            }
            .onCancel {
                deferred.promise.cancel()
            }

        promise3
            .onValue { value in
                value3 = value
                onOneValueSet()
            }
            .onError { error in
                deferred.reject(error)
            }
            .onCancel {
                deferred.promise.cancel()
            }

        promise4
            .onValue { value in
                value4 = value
                onOneValueSet()
            }
            .onError { error in
                deferred.reject(error)
            }
            .onCancel {
                deferred.promise.cancel()
            }

        promise5
            .onValue { value in
                value5 = value
                onOneValueSet()
            }
            .onError { error in
                deferred.reject(error)
            }
            .onCancel {
                deferred.promise.cancel()
            }

        return deferred.promise;
    }

    @discardableResult static func scheduleTimer(interval: TimeInterval = 0, repeats: Bool = false, handler: @escaping () -> Void) -> Timer {
        if !Thread.isMainThread {
            fatalError("scheduleTimer was called outside the main thread")
        }

        let wrapper = HandlerWrapper(handler: handler)
        return Timer.scheduledTimer(timeInterval: interval, target: wrapper, selector: #selector(HandlerWrapper.callHandler), userInfo: nil, repeats: repeats)
    }


    fileprivate class HandlerWrapper {
        let handler: () -> Void

        init (handler: @escaping () -> Void) {
            self.handler = handler
        }

        @objc fileprivate func callHandler() {
            handler()
        }
    }

}

private class WrapperHandler<ValueType, ChildValueType> {

    fileprivate let nestedOnValue: (_ value: ValueType, _ deferred: Deferred<ChildValueType>) -> Void

    let deferred: Deferred<ChildValueType>


    init(nestedOnValue: @escaping (_ value: ValueType, _ deferred: Deferred<ChildValueType>) -> Void) {
        self.nestedOnValue = nestedOnValue
        deferred = Deferred<ChildValueType>()
    }

    func onValue(_ value: ValueType) {
        // This is the then-handler. Then-handlers should be called after all other handlers
        // (because they are automatically at the end of a promise's method chain, since then returns a new promise)
        // -> Call our nestedOnValue after the current promise has finished flushing its handlers
        //    See test: PromiseTest.testSimpleValue
        PromiseUtil.executeOutsidePromiseHandlerFlush {
            self.nestedOnValue(value, self.deferred)
        }
    }

    func onError(_ error: Any) {
        deferred.reject(error)
    }

    func onCancel() {
        deferred.promise.cancel()
    }

}

// Before XCode 7.3 we could handle our implementations of PromiseUtil.all with this nice little helper class.
// But this is broken now. Swift is unable to handle optional types wrapped in a non-optional generic type properly.
// We keep the code - maybe one happy day Swift is fixed...
//
// Here is the code which shows that Swift bug:
//
//    let outerNil: Int? = nil
//    test(outerNil)
//
//    static func test<T>(value: T) {
//        dtLog("T: \(T.Type.self)")                                       // "T: Optional<CLLocation>.Type"
//        let innerNil: Int? = nil
//        dtLog("value    : \(value), type: \(value.dynamicType)")         // "value    : nil, type: Optional<CLLocation>"
//        dtLog("innerNil : \(innerNil), type: \(innerNil.dynamicType)")   // "innerNil : nil, type: Optional<CLLocation>"
//        let a = value as! T                                              // works
//        dtLog("a: \(a)")                                                 // "a: nil"
//        let b = innerNil as! T                                           // fatal error: unexpectedly found nil while unwrapping an Optional value
//        dtLog("b: \(b)")
//    }
//
//private class ParallelPromiseGroup {
//
//    private var gatheredValues = [Any?]()
//    private var pendingPromiseCount = 0
//    private var closed = false
//
//    private let deferred = Deferred<[Any?]>()
//
//
//    private func checkDone() {
//        if closed && pendingPromiseCount == 0 {
//            deferred.resolve(gatheredValues)
//        }
//    }
//
//    func addPromise<ValueType>(promise: Promise<ValueType>) -> ParallelPromiseGroup {
//        assert(!closed)
//
//        let index = gatheredValues.count
//        gatheredValues.append(nil)
//
//        pendingPromiseCount++
//        promise
//            .onValue { value in
//
//                self.gatheredValues[index] = value
//                self.pendingPromiseCount--;
//                self.checkDone()
//            }
//            .onError { error in
//                self.deferred.reject(error)
//            }
//            .onCancel {
//                self.deferred.promise.cancel()
//            }
//
//        return self
//    }
//
//    func allSettled() -> Promise<[Any?]> {
//        assert(!closed)
//
//        closed = true
//        checkDone()
//        return deferred.promise
//    }
//
//}
