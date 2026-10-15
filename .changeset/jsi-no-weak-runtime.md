---
'expo-modules-jsi': patch
---

[iOS] Remove all `weak` references to `JavaScriptRuntime`, which makes every retain and release of the runtime faster. Promises, callbacks, errors and the runtime actor hold the runtime handle instead, and code that runs off the JavaScript thread reads the runtime only on that thread.
