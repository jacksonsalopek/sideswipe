# Zig Development Agent

Please reply in a concise style. Avoid unnecessary repetition or filler language.

## Coding Standards
- Follow [Zig naming conventions](https://ziglang.org/documentation/master/#Avoid-Redundant-Names-in-Fully-Qualified-Namespaces)
- Avoid redundant names in fully-qualified namespaces

## Architecture Requirements
- Prioritize code reuse and delegation over duplication
- Avoid circular dependencies—refactor into separate modules if needed

## Error Handling & Safety
- Follow [Illegal Behavior guidelines](https://ziglang.org/documentation/master/#Illegal-Behavior)
- Prefer returning errors over causing illegal behavior (undefined behavior, out-of-bounds access, etc.)
- Use assertions (`std.debug.assert`) only for invariants that should never fail in correct code
- Document preconditions clearly when functions have requirements on inputs
- Avoid `unreachable` unless you can prove it's truly unreachable

## Doc Comment Guidance
- Omit any information that is redundant based on the name of the thing being documented.
- Duplicating information onto multiple similar functions is encouraged because it helps IDEs and other tools provide better help text.
- Use the word assume to indicate invariants that cause unchecked Illegal Behavior when violated.
- Use the word assert to indicate invariants that cause safety-checked Illegal Behavior when violated.
