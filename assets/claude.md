Role: Act as a Senior Flutter/Dart Software Architect.

Context: You now have full access to my entire workspace. I am building a comprehensive multi-engine network speed test application. So far, we have successfully implemented 7 distinct test engines: Real Speed Test International, Ookla, Fast.com, Cloudflare, Facebook CDN (FNA), Akamai, and Google CDN (GGC). We also integrated a TestLifecycle manager to handle phase transitions, zombie workers, and sockets.

My Situation: I am not a professional programmer. We got the app working perfectly across all these engines, but I know the code is highly repetitive, fragmented, and fragile. With 7 different engines, if I want to change how the HttpClient behaves, how chunks are generated, or how the EMA is calculated, I have to manually update it in 7 different files.

The Task:
DO NOT refactor or rewrite the codebase yet.
Your mission right now is to perform a deep architectural review of the entire project and generate a comprehensive strategic plan. Save this output strictly to a new file named review.md.

What review.md must contain:

Current State Analysis: A brief summary of the good parts of the architecture and the dangerous "tech debt" (code duplication, fragile logic, silent errors scattered across the 7 engines).

The "DRY" Strategy (Base Classes/Mixins): Explain conceptually how we can unify the repetitive Worker loops, chunk generation, EMA calculation, and Phase transitions into a single robust BaseSpeedTestEngine (or similar abstraction) that all 7 services can inherit from.

Actionable Phased Plan: Break down the refactoring process into strict, manageable phases so we don't break the app. Use this exact structure:

Phase 1: Cleanup & Foundation: Removing dead code, unused variables, and standardizing the TestLifecycle and SmoothSpeedMeter across all files.

Phase 2: Architectural Unification (The Base Class): Creating the parent engine and migrating one easy service (e.g., Cloudflare) to use it as a proof of concept.

Phase 3: Migrating Standard Engines: Moving Fast, Ookla, and FNA to the new Base Class architecture.

Phase 4: Migrating Complex/Custom Engines: Adapting the unique logic of Akamai, Google CDN (GGC), and Real Speed Test International to fit the unified Base Class.

Phase 5: UI / Logic Separation: Ensuring the UI state management is cleanly detached from the engine logic, ensuring the codebase is completely future-proofed.

Write review.md in clear, professional Markdown. Once you create the file, ask me: "Are you ready to begin Phase 1?"