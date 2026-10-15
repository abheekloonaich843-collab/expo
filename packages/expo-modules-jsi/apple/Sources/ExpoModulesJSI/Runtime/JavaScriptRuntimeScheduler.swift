// Copyright 2026-present 650 Industries. All rights reserved.

internal import ExpoModulesJSI_Cxx

extension JavaScriptRuntime {
  /// Schedules work on a runtime's JavaScript thread, and passes it the runtime there. The only
  /// implementation of `schedule`, `runOrSchedule` and `execute`: ``JavaScriptRuntime`` forwards to it,
  /// and promises and callbacks, which are settled, called and released from any thread, hold it instead
  /// of the runtime.
  ///
  /// Safe to use from any thread, also after the runtime is gone. It never reads the runtime off the
  /// JavaScript thread: the scheduled work reads it on that thread, where it can't race the runtime's
  /// `deinit`, so nothing needs a `weak` reference to the runtime. When the runtime is gone, scheduled
  /// work is dropped and `execute` throws ``JavaScriptCallback/RuntimeLostError``.
  ///
  /// This holds only when the scheduler dispatches to the JavaScript thread (``supportsAsyncScheduling``).
  /// The scheduler of a runtime created without a host scheduler (a standalone runtime, or
  /// `AppContext.setRuntime` without one) runs the work right away on the calling thread, so there the
  /// caller must not race the runtime's `deinit`.
  internal final class Scheduler: @unchecked Sendable {
    /// The engine-side scheduler. A task scheduled after the runtime is gone either runs and is dropped
    /// by the liveness check, or is dropped together with React Native's scheduler.
    private let pointee: expo.RuntimeScheduler

    /// The handle the scheduled work reads the runtime through, on the JavaScript thread.
    private let handle: JavaScriptRuntimeHandle

    /// Thread ID of the JavaScript thread, captured at construction time. Used by `isOnJavaScriptThread()`
    /// for a fast integer comparison instead of `Thread.current.name == "..."`. Assumes runtime
    /// initializers always run on the JS thread.
    private let jsThreadID: UInt64 = {
      var id: UInt64 = 0
      pthread_threadid_np(nil, &id)
      return id
    }()

    internal init(_ pointee: expo.RuntimeScheduler, handle: JavaScriptRuntimeHandle) {
      self.pointee = pointee
      self.handle = handle
    }

    /// Whether the runtime may still be alive. Safe to call from any thread. `false` is final; `true` may
    /// already be stale off the JavaScript thread, so the scheduled work checks again on that thread.
    @inline(__always)
    internal var mayBeAlive: Bool {
      return pointee.isRuntimeAlive()
    }

    /// Marks the runtime as gone. Called from the runtime's `deinit`.
    internal func markRuntimeGone() {
      pointee.markRuntimeGone()
    }

    /// Whether the scheduler dispatches work to the JavaScript thread. `false` for a runtime without a
    /// host scheduler, whose scheduled work runs right away on the calling thread.
    internal var supportsAsyncScheduling: Bool {
      return pointee.supportsAsyncScheduling()
    }

    /// Checks whether the function is called on the JavaScript thread.
    @inline(__always)
    internal func isOnJavaScriptThread() -> Bool {
      var current: UInt64 = 0
      pthread_threadid_np(nil, &current)
      return current == jsThreadID
    }

    // MARK: - Scheduling

    /// Schedules `body` on the JavaScript thread. Drops it when the runtime is gone by then.
    @inline(__always)
    internal func schedule(
      priority: JavaScriptRuntime.SchedulerPriority = .normal,
      _ body: @escaping @JavaScriptActor (JavaScriptRuntime) -> Void
    ) {
      let cxxPriority = expo.RuntimeScheduler.Priority(rawValue: priority.rawValue) ?? .NormalPriority
      pointee.scheduleTask(cxxPriority) { [handle] in
        JavaScriptActor.assumeIsolated {
          guard let runtime = handle.runtime else {
            return
          }
          body(runtime)
        }
      }
    }

    /// Schedules the async `body` on the JavaScript thread, started in a task there. Drops it when the
    /// runtime is gone by then.
    internal func schedule(
      priority: JavaScriptRuntime.SchedulerPriority = .normal,
      _ body: @escaping @JavaScriptActor (JavaScriptRuntime) async throws -> Void
    ) {
      schedule(priority: priority) { (runtime: JavaScriptRuntime) in
        Task.immediate_polyfill {
          try await body(runtime)
        }
      }
    }

    /// Runs `body` right away on the JavaScript thread, or schedules it otherwise. Drops it when the
    /// runtime is gone.
    @inline(__always)
    internal func runOrSchedule(
      priority: JavaScriptRuntime.SchedulerPriority = .normal,
      _ body: @escaping @JavaScriptActor (JavaScriptRuntime) -> Void
    ) {
      if isOnJavaScriptThread() {
        JavaScriptActor.assumeIsolated {
          guard let runtime = handle.runtime else {
            return
          }
          body(runtime)
        }
      } else {
        schedule(priority: priority, body)
      }
    }

    /// Runs `body` on the JavaScript thread and blocks the calling thread until it returns. Throws
    /// ``JavaScriptCallback/RuntimeLostError`` when the runtime is gone.
    @available(*, noasync)
    @inline(__always)
    internal func execute<R: Sendable>(_ body: @escaping @JavaScriptActor (JavaScriptRuntime) throws -> R) throws
      -> sending R
    {
      if isOnJavaScriptThread() {
        return try JavaScriptActor.assumeIsolated {
          return try body(try liveRuntime())
        }
      }
      guard mayBeAlive else {
        throw JavaScriptCallback.RuntimeLostError()
      }

      var result: Result<R, any Error>!
      let waiter = ThreadWaiter()

      pointee.scheduleTask(.ImmediatePriority) {
        do {
          result = .success(try JavaScriptActor.assumeIsolated { try body(try self.liveRuntime()) })
        } catch {
          result = .failure(error)
        }
        waiter.wake()
      }

      waiter.wait(until: {
        result != nil
      })
      return try result.get()
    }

    /// Runs the async `body` on the JavaScript thread and blocks the calling thread until it returns.
    /// Throws ``JavaScriptCallback/RuntimeLostError`` when the runtime is gone.
    @available(*, noasync)
    internal func execute<R: Sendable>(_ body: @escaping @JavaScriptActor (JavaScriptRuntime) async throws -> R) throws
      -> sending R
    {
      guard mayBeAlive else {
        throw JavaScriptCallback.RuntimeLostError()
      }
      let result = NonisolatedUnsafeVar<Result<R, any Error>>()
      let runInline = isOnJavaScriptThread()
      let waiter = ThreadWaiter()

      func run() {
        Task.immediate_polyfill(priority: .high) { @JavaScriptActor in
          do {
            result.value = .success(try await body(try self.liveRuntime()))
          } catch {
            result.value = .failure(error)
          }
          waiter.wake()
        }
      }
      if runInline {
        run()
      } else {
        pointee.scheduleTask(.ImmediatePriority, run)
      }

      waiter.wait(until: {
        result.value != nil
      })
      return try result.value.get()
    }

    /// Runs `body` on the JavaScript thread and suspends until it returns. Throws
    /// ``JavaScriptCallback/RuntimeLostError`` when the runtime is gone.
    @inline(__always)
    internal func execute<R: Sendable>(_ body: @escaping @JavaScriptActor (JavaScriptRuntime) throws -> R) async throws
      -> sending R
    {
      if isOnJavaScriptThread() {
        return try JavaScriptActor.assumeIsolated {
          return try body(try liveRuntime())
        }
      }
      guard mayBeAlive else {
        throw JavaScriptCallback.RuntimeLostError()
      }
      return try await withUnsafeThrowingContinuation { continuation in
        pointee.scheduleTask(.ImmediatePriority) {
          do {
            continuation.resume(returning: try JavaScriptActor.assumeIsolated { try body(try self.liveRuntime()) })
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    }

    /// Runs the async `body` on the JavaScript thread and suspends until it returns. Throws
    /// ``JavaScriptCallback/RuntimeLostError`` when the runtime is gone.
    internal func execute<R: Sendable>(
      _ body: @escaping @JavaScriptActor (JavaScriptRuntime) async throws -> R
    ) async throws -> sending R {
      if isOnJavaScriptThread() {
        let runtime = try JavaScriptActor.assumeIsolated { try liveRuntime() }
        return try await Task.immediate_polyfill(priority: .high) { @JavaScriptActor in
          try await body(runtime)
        }.value
      }
      guard mayBeAlive else {
        throw JavaScriptCallback.RuntimeLostError()
      }
      return try await withUnsafeThrowingContinuation { continuation in
        pointee.scheduleTask(.ImmediatePriority) {
          Task.immediate_polyfill(priority: .high) { @JavaScriptActor in
            do {
              continuation.resume(returning: try await body(try self.liveRuntime()))
            } catch {
              continuation.resume(throwing: error)
            }
          }
        }
      }
    }

    // MARK: - Scheduling without the runtime

    // For closures that don't need the runtime, such as those passed to ``JavaScriptRuntime``'s
    // `schedule`, `runOrSchedule` and `execute` overloads without a parameter. They check liveness
    // with ``JavaScriptRuntimeHandle/isAlive``, which costs no reference counting, and are dropped or
    // throw the same way when the runtime is gone.

    /// Schedules `closure` on the JavaScript thread. Drops it when the runtime is gone by then.
    @inline(__always)
    internal func schedule(
      priority: JavaScriptRuntime.SchedulerPriority = .normal,
      _ closure: @escaping @JavaScriptActor () -> sending Void
    ) {
      let cxxPriority = expo.RuntimeScheduler.Priority(rawValue: priority.rawValue) ?? .NormalPriority
      pointee.scheduleTask(cxxPriority) { [handle] in
        JavaScriptActor.assumeIsolated {
          guard handle.isAlive else {
            return
          }
          closure()
        }
      }
    }

    /// Schedules the async `closure` on the JavaScript thread, started in a task there. Drops it when the
    /// runtime is gone by then.
    internal func schedule(
      priority: JavaScriptRuntime.SchedulerPriority = .normal,
      _ closure: @escaping @JavaScriptActor () async throws -> Void
    ) {
      schedule(priority: priority) { () -> Void in
        Task.immediate_polyfill {
          try await closure()
        }
      }
    }

    /// Runs `closure` right away on the JavaScript thread, or schedules it otherwise. Drops it when the
    /// runtime is gone.
    @inline(__always)
    internal func runOrSchedule(
      priority: JavaScriptRuntime.SchedulerPriority = .normal,
      _ closure: @escaping @JavaScriptActor () -> Void
    ) {
      if isOnJavaScriptThread() {
        JavaScriptActor.assumeIsolated {
          guard handle.isAlive else {
            return
          }
          closure()
        }
      } else {
        schedule(priority: priority, closure)
      }
    }

    /// Runs `closure` on the JavaScript thread and blocks the calling thread until it returns. Throws
    /// ``JavaScriptCallback/RuntimeLostError`` when the runtime is gone.
    @available(*, noasync)
    @inline(__always)
    internal func execute<R: Sendable>(_ closure: @escaping @JavaScriptActor () throws -> R) throws -> sending R {
      if isOnJavaScriptThread() {
        return try JavaScriptActor.assumeIsolated {
          try checkAlive()
          return try closure()
        }
      }
      guard mayBeAlive else {
        throw JavaScriptCallback.RuntimeLostError()
      }

      var result: Result<R, any Error>!
      let waiter = ThreadWaiter()

      pointee.scheduleTask(.ImmediatePriority) {
        do {
          result = .success(
            try JavaScriptActor.assumeIsolated {
              try self.checkAlive()
              return try closure()
            }
          )
        } catch {
          result = .failure(error)
        }
        waiter.wake()
      }

      waiter.wait(until: {
        result != nil
      })
      return try result.get()
    }

    /// Runs `closure` on the JavaScript thread and suspends until it returns. Throws
    /// ``JavaScriptCallback/RuntimeLostError`` when the runtime is gone.
    @inline(__always)
    internal func execute<R: Sendable>(_ closure: @escaping @JavaScriptActor () throws -> R) async throws -> sending R {
      if isOnJavaScriptThread() {
        return try JavaScriptActor.assumeIsolated {
          try checkAlive()
          return try closure()
        }
      }
      guard mayBeAlive else {
        throw JavaScriptCallback.RuntimeLostError()
      }
      return try await withUnsafeThrowingContinuation { continuation in
        pointee.scheduleTask(.ImmediatePriority) {
          do {
            continuation.resume(
              returning: try JavaScriptActor.assumeIsolated {
                try self.checkAlive()
                return try closure()
              }
            )
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    }

    /// Runs the async `closure` on the JavaScript thread and blocks the calling thread until it returns.
    /// Throws ``JavaScriptCallback/RuntimeLostError`` when the runtime is gone.
    @available(*, noasync)
    internal func execute<R: Sendable>(_ closure: @escaping @JavaScriptActor () async throws -> R) throws -> sending R {
      return try execute { (_: JavaScriptRuntime) async throws -> R in
        try await closure()
      }
    }

    /// Runs the async `closure` on the JavaScript thread and suspends until it returns. Throws
    /// ``JavaScriptCallback/RuntimeLostError`` when the runtime is gone.
    internal func execute<R: Sendable>(_ closure: @escaping @JavaScriptActor () async throws -> R) async throws
      -> sending R
    {
      return try await execute { (_: JavaScriptRuntime) async throws -> R in
        try await closure()
      }
    }

    /// Throws ``JavaScriptCallback/RuntimeLostError`` when the runtime is gone. For the JavaScript thread.
    @JavaScriptActor
    @inline(__always)
    private func checkAlive() throws {
      guard handle.isAlive else {
        throw JavaScriptCallback.RuntimeLostError()
      }
    }

    /// The runtime, for the JavaScript thread. Throws ``JavaScriptCallback/RuntimeLostError`` when it is gone.
    @JavaScriptActor
    @inline(__always)
    private func liveRuntime() throws -> JavaScriptRuntime {
      guard let runtime = handle.runtime else {
        throw JavaScriptCallback.RuntimeLostError()
      }
      return runtime
    }
  }
}
