---
'expo-modules-jsi': patch
---

[iOS] Remove all `weak` references to `JavaScriptRuntime`, which makes every retain and release of the runtime faster. Promises, callbacks and the runtime actor hold the runtime's scheduler instead, which reads the runtime only on the JavaScript thread. `JavaScriptRuntime.schedule`, `runOrSchedule` and `execute` get overloads whose closure takes the runtime. All of them now drop the work when the runtime is gone by the time it runs, and `execute` throws `RuntimeLostError` then, so don't rely on them for work that must happen without the runtime.
