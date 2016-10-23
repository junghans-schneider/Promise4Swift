//
//  PromiseTest.swift
//
//  Created by Til Schneider <github@murfman.de> on 01.12.15.
//  Copyright © 2015 Junghans und Schneider. License: MIT
//  https://github.com/junghans-schneider/Promise4Swift
//

import XCTest
@testable import myproject

class PromiseTest: XCTestCase {

    private func examples() {
        // Normal chain, different handler types
        let promise = Promise(value: 1234)

        promise
            .then { (value, deferred: Deferred<String>) in
                // Nest other promise
                let nestedDeferred = Deferred<String>()
                nestedDeferred.resolve("Hallo")

                deferred.resolve(nestedDeferred.promise)
            }
            .onValue { value in
                // Use result
            }
            .onError { error in
                // Handle error
            }

        promise.cancel(wholeChain: true)

        /*
        // .all
        Promise promise1 = null;
        Promise promise2 = null;
        Promise promise3 = null;
        Promise.all("value", promise1, promise2, promise3)
            .then(new PromiseHandler<Object[]>() {
                @Override
                public Object onValue(Object[] values) {
                    // Use result
                    return null;
                }
                });
        */

        // Turn value into promise
        Promise(value: "value")
            .onValue { value in
                // Use result
                print("value: \(value)")
            }
    }

    // Put setup code here. This method is called before the invocation of each test method in the class.
    override func setUp() {
        super.setUp()
    }

    // Put teardown code here. This method is called after the invocation of each test method in the class.
    override func tearDown() {
        super.tearDown()

        PromiseFallbackErrorHandler = nil
    }

    func testSimpleValue() {
        var fin1Called   = false
        var thenCalled   = false
        var valueCalled  = false
        var fin2Called   = false
        let testFinished = self.expectation(description: "testSimpleValue finished")

        Promise(value: 1234)
            .onFinally {
                XCTAssertFalse(fin1Called)
                XCTAssertFalse(thenCalled)
                XCTAssertFalse(valueCalled)
                XCTAssertFalse(fin2Called)
                fin1Called = true
            }
            .then { (value, deferred: Deferred<String>) in
                XCTAssertTrue(fin1Called)
                XCTAssertFalse(thenCalled)
                XCTAssertFalse(valueCalled)
                XCTAssertFalse(fin2Called)
                thenCalled = true

                XCTAssertEqual(1234, value)
                deferred.resolve("my-result")
            }
            .onValue { value in
                XCTAssertTrue(fin1Called)
                XCTAssertTrue(thenCalled)
                XCTAssertFalse(valueCalled)
                XCTAssertFalse(fin2Called)
                valueCalled = true

                XCTAssertEqual("my-result", value)
            }
            .onFinally {
                XCTAssertTrue(fin1Called)
                XCTAssertTrue(thenCalled)
                XCTAssertTrue(valueCalled)
                XCTAssertFalse(fin2Called)
                fin2Called = true

                testFinished.fulfill()
            }

        // Handlers are called asynchronously
        XCTAssertFalse(fin1Called)
        XCTAssertFalse(thenCalled)
        XCTAssertFalse(valueCalled)
        XCTAssertFalse(fin2Called)

        waitForExpectations(timeout: 5, handler: nil)
    }

    func testComplexValue() {
        let testFinished  = self.expectation(description: "testComplexValue finished")

        let deferred1 = Deferred<Int>()

        let deferred2 = Deferred<Int>()
        deferred2.resolve(deferred1.promise)

        let deferred3 = Deferred<Int>()
        deferred3.resolve(deferred2.promise)

        deferred3.promise
            .then { (value, deferred) in
                deferred.resolve(value)
            }
            .then { (value, deferred) in
                deferred.resolve(value)
            }
            .then { (value, deferred: Deferred<String>) in
                XCTAssertEqual(1234, value)
                deferred.resolve("handler-called")
            }
            .then { (value, deferred) in
                deferred.resolve(value)
            }
            .onValue { value in
                XCTAssertEqual("handler-called", value)
                testFinished.fulfill()
            }

        deferred1.resolve(1234)

        waitForExpectations(timeout: 5, handler: nil)
    }

    func testSimpleError() {
        var failCalled    = false
        var finCalled     = false
        let testFinished  = self.expectation(description: "testSimpleError finished")

        let deferred = Deferred<Int>()
        deferred.reject("test error")

        deferred.promise
            .onError { error in
                XCTAssertEqual("test error", error as? String)
                XCTAssertFalse(failCalled)
                failCalled = true
            }
            .onFinally {
                XCTAssertTrue(failCalled)
                XCTAssertFalse(finCalled)
                finCalled = true

                testFinished.fulfill()
            }

        // Handlers are called asynchronously
        XCTAssertFalse(failCalled)
        XCTAssertFalse(finCalled)

        waitForExpectations(timeout: 5, handler: nil)
    }

    func testComplexError() {
        let testFinished  = self.expectation(description: "testComplexError finished")

        let deferred1 = Deferred<Int>()

        let deferred2 = Deferred<Int>()
        deferred2.resolve(deferred1.promise)

        let deferred3 = Deferred<Int>()
        deferred3.resolve(deferred2.promise)

        deferred3.promise
            .then { (value, deferred) in
                deferred.resolve(value)
            }
            .then { (value, deferred) in
                deferred.resolve(value)
            }
            .onError { error in
                XCTAssertEqual("test error", error as? String)
                testFinished.fulfill()
            }

        deferred1.reject("test error")

        waitForExpectations(timeout: 5, handler: nil)
    }

    func testFallbackError() {
        let testFinished  = self.expectation(description: "testFallbackError finished")

        var fallbackCalled = false
        var finCalled      = false

        // fallbackErrorHandler will be cleaned up in `tearDown`
        PromiseFallbackErrorHandler = { (error: Any) in
            XCTAssertEqual("test error", error as? String)
            XCTAssertFalse(fallbackCalled)
            fallbackCalled = true
        }

        let deferred = Deferred<Int>()
        deferred.reject("test error")

        deferred.promise
            .then { (value, deferred: Deferred<Int>) in
                XCTFail("then 1 was called after error")
                deferred.resolve(value)
            }
            .then { (value, deferred: Deferred<Int>) in
                XCTFail("then 1 was called after error")
                deferred.resolve(value)
            }
            .onFinally {
                XCTAssertTrue(fallbackCalled)
                XCTAssertFalse(finCalled)
                finCalled = true

                testFinished.fulfill()
            }

        XCTAssertFalse(fallbackCalled)
        XCTAssertFalse(finCalled)

        waitForExpectations(timeout: 5, handler: nil)
    }

    func testSimpleCancel() {
        var cancelCalled  = false
        var finCalled     = false

        let firstPromise = waitForever()
        firstPromise
            .onCancel {
                XCTAssertFalse(cancelCalled)
                cancelCalled = true
            }
            .onFinally {
                XCTAssertTrue(cancelCalled)
                XCTAssertFalse(finCalled)
                finCalled = true
            }

        XCTAssertFalse(cancelCalled)
        XCTAssertFalse(finCalled)

        firstPromise.cancel()

        XCTAssertTrue(cancelCalled)
        XCTAssertTrue(finCalled)
    }

    func testComplexCancelForward() {
        var handlerCalled = false
        var promises = [Promise<Int>]()

        let waitPromise = self.waitForever()
        promises.append(waitPromise)

        let middleDeferred = Deferred<Int>()
        middleDeferred.resolve(waitPromise)
        promises.append(middleDeferred.promise)

        let outerDeferred = Deferred<Int>()
        outerDeferred.resolve(middleDeferred.promise)
        let outerPromise = outerDeferred.promise
        promises.append(outerPromise)

        promises.append(outerPromise.then { (value, deferred) in
            deferred.resolve(value)
        })
        promises.append(promises.last!.then { (value, deferred) in
            deferred.resolve(value)
        })

        promises.append(promises.last!.onCancel {
            XCTAssertFalse(handlerCalled)
            handlerCalled = true
        })

        promises.append(promises.last!.then { (value, deferred) in
            deferred.resolve(value)
        })
        promises.append(promises.last!.then { (value, deferred) in
            deferred.resolve(value)
        })

        // execute test
        XCTAssertFalse(handlerCalled)
        for promise in promises {
            XCTAssertFalse(promise.isFinished)
            XCTAssertFalse(promise.isCancelled)
        }

        waitPromise.cancel()

        XCTAssertTrue(handlerCalled)
        for promise in promises {
            XCTAssertTrue(promise.isFinished)
            XCTAssertTrue(promise.isCancelled)
        }
    }

    func testComplexCancelBackward() {
        doTestComplexCancelBackward(wholeChain: false, withCancellable: true)
        doTestComplexCancelBackward(wholeChain: false, withCancellable: false)
        doTestComplexCancelBackward(wholeChain: true,  withCancellable: true)
        doTestComplexCancelBackward(wholeChain: true,  withCancellable: false)
    }

    func doTestComplexCancelBackward(wholeChain: Bool, withCancellable: Bool) {
        var handlerCalled = false
        var nonCancellablePromises = [Promise<Int>]()
        var promises = [Promise<Int>]()

        let waitPromise = self.waitForever()
        if withCancellable {
            // The waitPromise will be protected from beeing cancelled by the middlePromise
            nonCancellablePromises.append(waitPromise)
        } else {
            promises.append(waitPromise)
        }

        let middleDeferred = Deferred<Int>()
        middleDeferred.resolve(waitPromise)
        let middlePromise = middleDeferred.promise
        if withCancellable {
            middlePromise.cancellable = false
            nonCancellablePromises.append(middlePromise)
        } else {
            promises.append(middlePromise)
        }

        let outerDeferred = Deferred<Int>()
        outerDeferred.resolve(middlePromise)
        let outerPromise = outerDeferred.promise
        promises.append(outerPromise)

        promises.append(outerPromise.then { (value, deferred) in
            deferred.resolve(value)
        })
        promises.append(promises.last!.then { (value, deferred) in
            deferred.resolve(value)
        })

        promises.append(promises.last!.onCancel {
            XCTAssertFalse(handlerCalled)
            handlerCalled = true
        })

        promises.append(promises.last!.then { (value, deferred) in
            deferred.resolve(value)
        })
        promises.append(promises.last!.then { (value, deferred) in
            deferred.resolve(value)
        })

        // execute test
        XCTAssertFalse(handlerCalled)
        for promise in nonCancellablePromises {
            XCTAssertFalse(promise.isFinished)
            XCTAssertFalse(promise.isCancelled)
        }
        for promise in promises {
            XCTAssertFalse(promise.isFinished)
            XCTAssertFalse(promise.isCancelled)
        }

        let lastPromise = promises.last!
        lastPromise.cancel(wholeChain: wholeChain)

        XCTAssertEqual(wholeChain, handlerCalled)
        for promise in nonCancellablePromises {
            XCTAssertFalse(promise.isFinished)
            XCTAssertFalse(promise.isCancelled)
        }
        for promise in promises {
            let expectCancelled = (wholeChain || promise === lastPromise)
            XCTAssertEqual(expectCancelled, promise.isFinished)
            XCTAssertEqual(expectCancelled, promise.isCancelled)
        }
    }

    /*
    public void testAllEmpty() {
        final boolean[] handlerCalled = new boolean[] { false };
        Promise.all()
            .then(new PromiseHandler<Object[]>() {
                @Override
                public Object onValue(Object[] values) throws Throwable {
                    handlerCalled[0] = true;
                    assertEquals(0, values.length);
                    return null;
                }
                });
        assertTrue(handlerCalled[0]);
    }

    public void testAllValuesOnly() {
        final boolean[] handlerCalled = new boolean[] { false };
        Promise.all(123, "Hallo", true, 12.8d)
        .then(new PromiseHandler<Object[]>() {
            @Override
            public Object onValue(Object[] values) throws Throwable {
                handlerCalled[0] = true;
                assertEquals(4, values.length);
                assertEquals(123, ((Integer) values[0]).intValue());
                assertEquals("Hallo", values[1]);
                assertEquals(true, ((Boolean) values[2]).booleanValue());
                assertEquals(12.8, ((Double) values[3]).doubleValue());
                return null;
            }
            });
        assertTrue(handlerCalled[0]);
    }

    public void testAllDone() throws Exception {
        final boolean[] handlerCalled = new boolean[] { false };

        final Thread mainThread = Thread.currentThread();
        ExecutorService bgExecutor = Executors.newSingleThreadExecutor();

        Promise promise1 = Promise.when(1234);
        Promise promise2 = new Promise(bgExecutor) {
            @Override
            protected void execute(Resolver resolver) {
                assertFalse(Thread.currentThread() == mainThread);
                try {
                    Thread.sleep(50);
                } catch (InterruptedException exc) {
                }
                resolver.done("Bla");
            }
        };
        Promise promise3 = new Promise(bgExecutor) {
            @Override
            protected void execute(Resolver resolver) {
                assertFalse(Thread.currentThread() == mainThread);
                try {
                    Thread.sleep(10);
                } catch (InterruptedException exc) {
                }
                resolver.done(false);
            }
        };

        Promise outerPromise = Promise.all("Hallo", promise1, promise2, promise3)
            .then(new PromiseHandler<Object[]>() {
                @Override
                public Object onValue(Object[] values) throws Throwable {
                    handlerCalled[0] = true;
                    assertEquals(4, values.length);
                    assertEquals("Hallo", values[0]);
                    assertEquals(1234, ((Integer) values[1]).intValue());
                    assertEquals("Bla", values[2]);
                    assertEquals(false, ((Boolean) values[3]).booleanValue());
                    return null;
                }
                });

        outerPromise.waitForResult();
        assertTrue(handlerCalled[0]);
    }

    public void testAllError() throws Exception {
        final boolean[] handlerCalled = new boolean[] { false };

        final Thread mainThread = Thread.currentThread();
        ExecutorService bgExecutor = getBgExecutor();

        Promise promise1 = Promise.when(1234);
        Promise promise2 = new Promise(bgExecutor) {
            @Override
            protected void execute(Resolver resolver) {
                assertFalse(Thread.currentThread() == mainThread);
                try {
                    Thread.sleep(50);
                } catch (InterruptedException exc) {
                }
                throw new RuntimeException("Test");
            }
        };
        Promise promise3 = new Promise(bgExecutor) {
            @Override
            protected void execute(Resolver resolver) {
                assertFalse(Thread.currentThread() == mainThread);
                try {
                    Thread.sleep(10);
                } catch (InterruptedException exc) {
                }
                resolver.done(false);
            }
        };

        Promise outerPromise = Promise.all("Hallo", promise1, promise2, promise3)
            .then(new PromiseHandler<Object[]>() {
                @Override
                public Object onError(Throwable thr) throws Throwable {
                    handlerCalled[0] = true;
                    assertTrue(thr instanceof RuntimeException);
                    assertEquals("Test", thr.getMessage());
                    return null;
                }
                });

        outerPromise.waitForResult();
        assertTrue(handlerCalled[0]);
    }

    public void testAllCancelForward() {
        final boolean[] handlerCalled = new boolean[] { false };

        Promise promise1 = waitForever();
        Promise promise2 = waitForever();
        Promise promise3 = waitForever();
        Promise allPromise = Promise.all(promise1, promise2, promise3);
        Promise handlerPromise = allPromise.then(new PromiseHandler<Object[]>() {
            @Override
            public void onCancel() {
                handlerCalled[0] = true;
            }
            });

        assertFalse(handlerCalled[0]);
        assertFalse(promise1.isFinished());
        assertFalse(promise2.isFinished());
        assertFalse(promise3.isFinished());
        assertFalse(allPromise.isFinished());
        assertFalse(handlerPromise.isFinished());

        promise2.cancel();

        assertTrue(handlerCalled[0]);
        assertFalse(promise1.isFinished());
        assertTrue(promise2.isCancelled());
        assertFalse(promise3.isFinished());
        assertTrue(allPromise.isCancelled());
        assertTrue(handlerPromise.isCancelled());
    }

    public void testAllCancelBackward() {
        doTestAllCancelBackward(false);
        doTestAllCancelBackward(true);
    }

    private void doTestAllCancelBackward(boolean wholeChain) {
        final boolean[] handlerCalled = new boolean[] { false };

        Promise promise1 = waitForever();
        Promise promise2 = waitForever();
        Promise promise3 = waitForever();
        Promise allPromise = Promise.all(promise1, promise2, promise3);
        Promise handlerPromise = allPromise.then(new PromiseHandler<Object[]>() {
            @Override
            public void onCancel() {
                handlerCalled[0] = true;
            }
            });
        Promise lastPromise = handlerPromise.then(new PromiseHandler<Object>() {
            });

        assertFalse(handlerCalled[0]);
        assertFalse(promise1.isFinished());
        assertFalse(promise2.isFinished());
        assertFalse(promise3.isFinished());
        assertFalse(allPromise.isFinished());
        assertFalse(handlerPromise.isFinished());
        assertFalse(lastPromise.isFinished());

        lastPromise.cancel(wholeChain);

        assertEquals(wholeChain, handlerCalled[0]);
        assertEquals(wholeChain, promise1.isCancelled());
        assertEquals(wholeChain, promise2.isCancelled());
        assertEquals(wholeChain, promise3.isCancelled());
        assertEquals(wholeChain, allPromise.isCancelled());
        assertEquals(wholeChain, handlerPromise.isCancelled());
        assertTrue(lastPromise.isFinished());
    }

    public void testDynamicChain() throws Throwable {
        Promise promise = loadParkings(10, 30);
        @SuppressWarnings("unchecked")
        List<Object> parkingList = (List<Object>) promise.waitForResult();
        assertTrue(parkingList.size() >= 30);
    }

    private Promise loadParkings(final int radius, final int minResultSize) {
        return new Promise() {
            @Override
            protected void execute(Resolver resolver) {
                List<Object> parkingList = Arrays.asList(new Object[radius]);
                resolver.done(parkingList);
            }
            }.then(new PromiseHandler<List<Object>>() {
                @Override
                public Object onValue(List<Object> parkingList) {
                    if (parkingList.size() < minResultSize) {
                        return loadParkings(radius + 10, minResultSize);
                    } else {
                        return parkingList;
                    }
                }
                });
    }
    */

    private func waitForever() -> Promise<Int> {
        let deferred = Deferred<Int>()
        return deferred.promise
    }

}
