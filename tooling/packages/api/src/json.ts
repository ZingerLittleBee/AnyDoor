// JSON value model shared by the key-value store and any structured capability
// payload. Matches the host's `ScriptValue` (null | bool | number | string |
// array | object), the only shape that crosses the Swift <-> JavaScript
// boundary.

export type JSONValue =
  | null
  | boolean
  | number
  | string
  | JSONValue[]
  | { [key: string]: JSONValue };
