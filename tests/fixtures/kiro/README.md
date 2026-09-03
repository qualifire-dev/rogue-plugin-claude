# Kiro hook payload fixtures

Verbatim stdin payloads captured on 2026-09-03 from Kiro CLI 2.21.0 (2.x engine: `cli2-*`, 3.0 engine: `cli3-*`) and Kiro IDE 1.0.437 (`ide-*`). Only `cwd` and workspace paths were rewritten to `/workspace`. Session ids are real but throwaway. The 2.x engine sends no `session_id`; it exposes `KIRO_SESSION_ID` in the hook's environment instead. See FIRE-2030 for the measured block semantics.
