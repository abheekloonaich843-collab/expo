// Copyright 2026-present 650 Industries. All rights reserved.

internal import ExpoModulesJSI_Cxx
internal import jsi

/// A strong handle to a ``JavaScriptRuntime`` that values, promises and callbacks hold instead of a
/// `weak` reference to the runtime itself. Nothing references the runtime `weak`.
///
/// A `weak` reference gives the runtime a side table, and from then on every strong retain and
/// release of the runtime takes the slow atomic path, on top of the cost of the weak loads, stores and
/// destroys. Values did all of these on every access. The handle is never weakly referenced, so the
/// retain and release that storing it costs stay on the inline fast path, and reading the engine
/// runtime through it costs no ARC at all: `IRuntime` is imported as an immortal reference.
///
/// The runtime owns its handle and marks it dead in `deinit`, so values that outlive the runtime still
/// detect it through ``runtime`` or ``pointee`` returning `nil`.
///
/// Unlike a `weak` reference, ``runtime`` and ``pointee`` are not atomic and don't keep the runtime
/// alive for the rest of the call, so they are for the JavaScript thread only. They can't race the
/// runtime's `deinit` there, which holds as long as the last reference to the runtime is released on
/// the JavaScript thread (as `AppContext.destroy()` does). Code that runs on any thread, such as
/// settling a promise or calling a callback, uses the API under "Use from any thread" instead.
///
/// Not to be confused with the engine's handles to JavaScript values (`jsi::PointerValue`).
internal final class JavaScriptRuntimeHandle: @unchecked Sendable {
  /// The runtime that owns this handle, cleared by the runtime's `deinit`. Read it through ``runtime``
  /// instead.
  private unowned(unsafe) var unsafeRuntime: JavaScriptRuntime?

  /// The engine runtime, cleared by the runtime's `deinit`. Liveness is checked on this field rather
  /// than on ``unsafeRuntime``: `IRuntime` is an immortal reference, so reading it and checking it for
  /// `nil` costs no reference counting, whereas checking the runtime reference for `nil` retains the
  /// runtime, which is the slow-path traffic this handle exists to avoid.
  nonisolated(unsafe) private var jsiRuntime: facebook.jsi.IRuntime?

  /// The runtime's scheduler. Unlike the runtime, it is safe to use from any thread, also after the
  /// runtime is gone: a task scheduled then either runs and finds ``runtime`` empty, or is dropped
  /// together with React Native's scheduler.
  internal let scheduler: expo.RuntimeScheduler

  /// Thread ID of the JavaScript thread, captured at construction time. Used by `isOnJavaScriptThread()`
  /// for a fast integer comparison instead of `Thread.current.name == "..."`. Assumes runtime
  /// initializers always run on the JS thread.
  private let jsThreadID: UInt64 = {
    var id: UInt64 = 0
    pthread_threadid_np(nil, &id)
    return id
  }()

  internal init(_ pointee: facebook.jsi.IRuntime, scheduler: expo.RuntimeScheduler) {
    self.jsiRuntime = pointee
    self.scheduler = scheduler
  }

  /// Links the handle to its runtime. Called at the end of the runtime's initializers, once `self`
  /// is available.
  internal func attach(_ runtime: JavaScriptRuntime) {
    unsafeRuntime = runtime
  }

  /// Marks the runtime as gone. Called from the runtime's `deinit`.
  internal func detach() {
    scheduler.markRuntimeGone()
    jsiRuntime = nil
    unsafeRuntime = nil
  }

  /// Whether the runtime that owns this handle is still alive.
  @inline(__always)
  internal var isAlive: Bool {
    return jsiRuntime != nil
  }

  /// The runtime, or `nil` if it has been deallocated.
  @inline(__always)
  internal var runtime: JavaScriptRuntime? {
    return isAlive ? unsafeRuntime : nil
  }

  /// The engine runtime, or `nil` if the runtime has been deallocated.
  @inline(__always)
  internal var pointee: facebook.jsi.IRuntime? {
    return jsiRuntime
  }

  // MARK: - Use from any thread

  // Code that runs off the JavaScript thread (settling a promise, calling a callback, releasing either
  // of them) goes through these instead of holding the runtime. It never reads the runtime there: it
  // only schedules, and the scheduled work reads ``runtime`` on the JavaScript thread, where it can't
  // race the runtime's `deinit`. So the runtime needs no `weak` references.
  //
  // This holds only when the scheduler dispatches to the JavaScript thread (`supportsAsyncScheduling`).
  // The scheduler of a runtime created without a host scheduler (a standalone runtime, or
  // `AppContext.setRuntime` without one) runs the work right away on the calling thread, so there the
  // work reads ``runtime`` on that thread, and the caller must not race the runtime's `deinit`.

  /// Whether the runtime may still be alive. Safe to call from any thread. `false` is final; `true` may
  /// already be stale off the JavaScript thread, so work scheduled after a `true` must check
  /// ``runtime`` again on the JavaScript thread.
  internal var mayBeAlive: Bool {
    return scheduler.isRuntimeAlive()
  }

  /// Checks whether the function is called on the JavaScript thread.
  @inline(__always)
  internal func isOnJavaScriptThread() -> Bool {
    var current: UInt64 = 0
    pthread_threadid_np(nil, &current)
    return current == jsThreadID
  }

  /// Whether the scheduler dispatches work to the JavaScript thread. `false` for a runtime without a
  /// host scheduler, whose scheduled work runs right away on the calling thread.
  internal var supportsAsyncScheduling: Bool {
    return scheduler.supportsAsyncScheduling()
  }

  // MARK: - Scheduling

  // The only implementation of scheduling onto the JavaScript thread. ``JavaScriptRuntime``'s public
  // `schedule`, `execute` and `runOrSchedule` forward to the overloads that take a closure without
  // parameters. Code that runs off the JavaScript thread and doesn't hold the runtime uses the
  // overloads that take a `(JavaScriptRuntime)` closure: they read the runtime on the JavaScript
  // thread and drop the work, or throw ``JavaScriptCallback/RuntimeLostError``, when it is gone.
  //
  // Both kinds go through the same functions, as a work value that runs the closure.
  // The scheduled block captures that value directly, so the liveness check costs no extra closure
  // or allocation.

  /// Schedules `closure` on the JavaScript thread.
  internal func schedule(
    priority: JavaScriptRuntime.SchedulerPriority = .normal,
    _ closure: @escaping @JavaScriptActor () -> sending Void
  ) {
    schedule(priority: priority, work: PlainVoidWork(closure: closure))
  }

  /// Schedules `body` on the JavaScript thread with the runtime. Drops it when the runtime is gone.
  internal func schedule(
    priority: JavaScriptRuntime.SchedulerPriority = .normal,
    _ body: @escaping @JavaScriptActor (JavaScriptRuntime) -> Void
  ) {
    schedule(priority: priority, work: RuntimeVoidWork(body: body))
  }

  /// Schedules the async `closure` on the JavaScript thread, started in a task there.
  internal func schedule(
    priority: JavaScriptRuntime.SchedulerPriority = .normal,
    _ closure: @escaping @JavaScriptActor () async throws -> Void
  ) {
    schedule(priority: priority) {
      Task.immediate_polyfill {
        try await closure()
      }
    }
  }

  /// Runs `closure` right away on the JavaScript thread, or schedules it otherwise.
  internal func runOrSchedule(
    priority: JavaScriptRuntime.SchedulerPriority = .normal,
    _ closure: @escaping @JavaScriptActor () -> Void
  ) {
    runOrSchedule(priority: priority, work: PlainVoidWork(closure: closure))
  }

  /// Runs `body` with the runtime right away on the JavaScript thread, or schedules it otherwise.
  /// Drops it when the runtime is gone.
  internal func runOrSchedule(
    priority: JavaScriptRuntime.SchedulerPriority = .normal,
    _ body: @escaping @JavaScriptActor (JavaScriptRuntime) -> Void
  ) {
    runOrSchedule(priority: priority, work: RuntimeVoidWork(body: body))
  }

  /// Runs `closure` on the JavaScript thread and blocks the calling thread until it returns.
  @available(*, noasync)
  internal func execute<R: Sendable>(_ closure: @escaping @JavaScriptActor () throws -> R) throws -> sending R {
    return try execute(work: .plain(closure))
  }

  /// Runs `body` with the runtime on the JavaScript thread and blocks the calling thread until it
  /// returns. Throws ``JavaScriptCallback/RuntimeLostError`` when the runtime is gone.
  @available(*, noasync)
  internal func execute<R: Sendable>(_ body: @escaping @JavaScriptActor (JavaScriptRuntime) throws -> R) throws
    -> sending R
  {
    guard mayBeAlive else {
      throw JavaScriptCallback.RuntimeLostError()
    }
    return try execute(work: .withRuntime(body))
  }

  /// Runs `closure` on the JavaScript thread and suspends until it returns.
  internal func execute<R: Sendable>(_ closure: @escaping @JavaScriptActor () throws -> R) async throws -> sending R {
    return try await execute(work: .plain(closure))
  }

  /// Runs `body` with the runtime on the JavaScript thread and suspends until it returns. Throws
  /// ``JavaScriptCallback/RuntimeLostError`` when the runtime is gone.
  internal func execute<R: Sendable>(_ body: @escaping @JavaScriptActor (JavaScriptRuntime) throws -> R) async throws
    -> sending R
  {
    guard mayBeAlive else {
      throw JavaScriptCallback.RuntimeLostError()
    }
    return try await execute(work: .withRuntime(body))
  }

  /// Runs the async `closure` on the JavaScript thread and blocks the calling thread until it returns.
  @available(*, noasync)
  internal func execute<R: Sendable>(_ closure: @escaping @JavaScriptActor () async throws -> R) throws -> sending R {
    let result = NonisolatedUnsafeVar<Result<R, any Error>>()
    let runInline = isOnJavaScriptThread()
    let waiter = ThreadWaiter()

    func body() {
      Task.immediate_polyfill(priority: .high) {
        do {
          result.value = .success(try await closure())
        } catch {
          result.value = .failure(error)
        }
        waiter.wake()
      }
    }
    if runInline {
      body()
    } else {
      scheduler.scheduleTask(.ImmediatePriority, body)
    }

    waiter.wait(until: {
      result.value != nil
    })
    return try result.value.get()
  }

  /// Runs the async `closure` on the JavaScript thread and suspends until it returns.
  internal func execute<R: Sendable>(_ closure: @escaping @JavaScriptActor () async throws -> R) async throws
    -> sending R
  {
    if isOnJavaScriptThread() {
      return try await Task.immediate_polyfill(priority: .high, operation: closure).value
    }
    return try await withUnsafeThrowingContinuation { continuation in
      scheduler.scheduleTask(.ImmediatePriority) {
        Task.immediate_polyfill(priority: .high) { @JavaScriptActor in
          do {
            continuation.resume(returning: try await closure())
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    }
  }

  // MARK: - Scheduling implementation

  // These and the work types' `run` are inlined: otherwise the scheduled block calls through one more
  // level, which measured about 10 ns more for each promise or callback release.

  @inline(__always)
  private func schedule<W: VoidThreadWork>(priority: JavaScriptRuntime.SchedulerPriority, work: W) {
    let cxxPriority = expo.RuntimeScheduler.Priority(rawValue: priority.rawValue) ?? .NormalPriority
    scheduler.scheduleTask(cxxPriority) {
      JavaScriptActor.assumeIsolated {
        work.run(on: self)
      }
    }
  }

  @inline(__always)
  private func runOrSchedule<W: VoidThreadWork>(priority: JavaScriptRuntime.SchedulerPriority, work: W) {
    if isOnJavaScriptThread() {
      JavaScriptActor.assumeIsolated {
        work.run(on: self)
      }
    } else {
      schedule(priority: priority, work: work)
    }
  }

  @available(*, noasync)
  @inline(__always)
  private func execute<R: Sendable>(work: ExecuteWork<R>) throws -> sending R {
    if isOnJavaScriptThread() {
      return try JavaScriptActor.assumeIsolated {
        return try work.run(on: self)
      }
    }

    var result: Result<R, any Error>!
    let waiter = ThreadWaiter()

    scheduler.scheduleTask(.ImmediatePriority) {
      do {
        result = .success(try JavaScriptActor.assumeIsolated { try work.run(on: self) })
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

  @inline(__always)
  private func execute<R: Sendable>(work: ExecuteWork<R>) async throws -> sending R {
    if isOnJavaScriptThread() {
      return try JavaScriptActor.assumeIsolated {
        return try work.run(on: self)
      }
    }
    return try await withUnsafeThrowingContinuation { continuation in
      scheduler.scheduleTask(.ImmediatePriority) {
        do {
          continuation.resume(returning: try JavaScriptActor.assumeIsolated { try work.run(on: self) })
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}

/// Work with a result that ``JavaScriptRuntimeHandle`` runs on the JavaScript thread. An enum rather
/// than a protocol: `execute` is called from generic code that isn't specialized for the result type,
/// where a protocol would look up its witness table and associated type on every call.
private enum ExecuteWork<Output>: @unchecked Sendable {
  /// A closure that doesn't need the runtime.
  case plain(@JavaScriptActor () throws -> Output)
  /// A closure with the runtime, read on the JavaScript thread. Throws
  /// ``JavaScriptCallback/RuntimeLostError`` without the runtime.
  case withRuntime(@JavaScriptActor (JavaScriptRuntime) throws -> Output)

  @JavaScriptActor
  @inline(__always)
  func run(on handle: JavaScriptRuntimeHandle) throws -> Output {
    switch self {
    case .plain(let closure):
      return try closure()
    case .withRuntime(let body):
      guard let runtime = handle.runtime else {
        throw JavaScriptCallback.RuntimeLostError()
      }
      return try body(runtime)
    }
  }
}

/// Work without a result that ``JavaScriptRuntimeHandle`` schedules on the JavaScript thread. Separate
/// from ``ExecuteWork``, so the closures keep their concrete `Void` type: stored in a generic
/// `ExecuteWork<Void>`, each would be wrapped in a heap-allocated reabstraction thunk on every call.
private protocol VoidThreadWork: Sendable {
  @JavaScriptActor
  func run(on handle: JavaScriptRuntimeHandle)
}

/// Runs a closure that doesn't need the runtime.
private struct PlainVoidWork: VoidThreadWork, @unchecked Sendable {
  let closure: @JavaScriptActor () -> Void

  @JavaScriptActor
  @inline(__always)
  func run(on handle: JavaScriptRuntimeHandle) {
    closure()
  }
}

/// Runs a closure with the runtime, read on the JavaScript thread. Dropped without the runtime.
private struct RuntimeVoidWork: VoidThreadWork, @unchecked Sendable {
  let body: @JavaScriptActor (JavaScriptRuntime) -> Void

  @JavaScriptActor
  @inline(__always)
  func run(on handle: JavaScriptRuntimeHandle) {
    guard let runtime = handle.runtime else {
      return
    }
    body(runtime)
  }
}
