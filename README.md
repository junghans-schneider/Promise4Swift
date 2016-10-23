Promise4Swift
=============

A promise implementation for Swift.
The API is inspired by [Q promises](https://github.com/kriskowal/q).

A promise represents an asynchronous task. By chaining other tasks and event handlers they help creating much cleaner
and maintainable code as when using completion handlers.

Promise4Swift uses **Swift 3**. Still using Swift 2? Check out [Release 1](https://github.com/junghans-schneider/Promise4Swift/releases/tag/1).


How to use Promise4Swift
------------------------

Just add the `Promise.swift` source file to your project.


Why promises?
-------------

### Avoid the pyramid of doom

Using promises you can mitigate the “Pyramid of Doom”: the situation where code marches to the right faster than it
marches forward.

~~~swift
step1(completionHandler: (value1) {
    step2(param: value1, completionHandler: (value2) {
        step3(param: value2, completionHandler: (value3) {
            step4(param: value3, completionHandler: function(value4) {
                // Do something with value4
            })
        })
    })
})
~~~

With promises, you can flatten the pyramid.

~~~swift
promisedStep1()
    .then(promisedStep2)
    .then(promisedStep3)
    .then(promisedStep4)
    .onValue { value4 in
        // Do something with value4
    }
    .onError { error in
        // Handle any error from all above steps
    }
~~~

As you can see, promises also make error handling easier. Instead of having to handle with errors in every single
handler, you can just add one error handler at the end of the chain. If one of the steps fails, the following steps will be skipped and the error handler will be called.


### Three states

A promise can finish in one of three states: successfull, error or cancelled. You can react on each of these states by
using the appropriate handler: `onValue`, `onError` or `onCancel`. Only one of these handlers will be called and 
it will be called only once. You also can add a `onFinally` handler which will always be called.

~~~swift
loadStuff()
    .onValue { stuff ->
        // Will be called once when the promise finished successfully
    }
    .onError { error ->
        // Will be called once when the promise finished with an error
    }
    .onCancel {
        // Will be called once when the promise finished was cancelled
    }
    .onFinally {
        // Will be called once when the promise finished
    }
~~~

No strange errors any more coming from poorly dealing with completion handlers where an error is propagated after a
timeout and seconds later the loaded data is propagates because the server finally responded.


### Sharing a promise

It doesn't matter if you add a handler to a promise before or after the associated asynchronous task has finished.
If you add your handler before, it will be called as soon as the task has finished. If you add you handler after,
it will be called immediately (but still asynchronously).

This can be used for sharing the same promise among multiple usages. Imagine you have to load something from a server
which doesn't change but is used multiple times in your UI - the user's name and mail address for instance.
With promises you can provide this information to multiple views, but load it only once:

~~~swift
class ServiceClient {
    fileprivate var userPromise: Promise<User>?

    func getUser() -> Promise<User> {
        if let userPromise = userPromise {
            return userPromise
        } else {
            return userPromise = loadUser()
        }
    }
}
~~~


### Manage parallel tasks

Using promises you can easily run tasks in parallel and combine their results as soon as they have finished.

~~~swift
showSpinner()
PromiseUtil.all(getCurrentLocation(), loadStuffFromServer())
    .onValue { results ->
        let (location, serverStuff) = results
        // Work with the location and the server stuff
    }
    .onError { error ->
        // Handle any error
    }
    .onFinally {
        hideSpinner()
    }
~~~


### Cancelling

Promise4Swift also supports cancelling a promise. Imagine you have a view showing data coming from a server.
If the user leaves the view before the data finished loading you can call `.cancel()` on your promise, so the dismissed
view won't be bothered with the obsolete result. 

~~~swift
class MyViewController: ... {

    var runningRequest: Promise<ServerStuff>?


    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        showSpinner()
        runningRequest = loadStuff()
            .onValue { stuff ->
                showStuff(stuff)
            }
            .onError { error ->
                // Handle any error
            }
            .onCancel {
                // Handle cancel (if needed)
            }
            .onFinally {
                runningRequest = nil
                hideSpinner()
            }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        if let runningRequest = runningRequest {
            runningRequest.cancel()
        }
    }

}
~~~
