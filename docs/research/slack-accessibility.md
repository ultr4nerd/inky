# Slack de escritorio y Accesibilidad de macOS

Probado el 2026-11-11 en macOS 26 (Darwin 25.6), Slack de escritorio (Electron/Chromium). Scripts en `spikes/`.

## Activación
- `AXUIElementSetAttributeValue(app, "AXManualAccessibility", true)` → éxito. Expone el árbol de Chromium.
- `AXEnhancedUserInterface` → `-25208` (no implementado). No hace falta.
- `kAXFocusedUIElement` de la app solo devuelve el campo cuando Slack está al frente. En segundo plano hay que recorrer la ventana buscando `AXTextArea` con `AXFocused = true`.

## Campo de mensaje
- Rol `AXTextArea` ("text entry area").
- `AXValue`: legible, texto plano. Las menciones aparecen como `@Nombre`.
- Hijos: `AXGroup` (párrafo) → `AXStaticText` por tramo. Cada mención es su propio `AXStaticText`:
  `"hey "` · `"@name"` · `" this are a test for the meeting"`.
- `AXAttributedStringForRange` solo trae `AXFont` y `AXForegroundColor`; no marca menciones.

## Posiciones en pantalla
| Método | Resultado |
|---|---|
| `AXBoundsForRange` | Éxito, pero rect vacío `(0, 982, 0, 0)`. Inservible. |
| `AXBoundsForTextMarkerRange` con `AXSelectedTextMarkerRange` | Rects reales por palabra. Requiere mover la selección → no apto para modo en vivo tal cual. |
| `AXFrame` de cada `AXStaticText` | Rects por tramo. Útil como respaldo. |

Pendiente (Fase 2): construir text markers sin mover la selección (`AXStartTextMarker` + `AXNextTextMarkerForTextMarker` / `AXTextMarkerRangeForUnorderedTextMarkers`).

## Escritura
| Método | Resultado |
|---|---|
| `AXReplaceRangeWithText` (`[range, text]`) | `-25212`. Anunciado pero no funciona. |
| `AXSelectedTextRange` + `AXSelectedText` | Ambos devuelven éxito; Slack ignora el texto. |
| `AXSelectedTextRange` + teclear con `CGEvent` unicode | ✅ Reemplaza solo el rango. La mención sigue siendo mención (verificado visualmente). |

Escribir requiere que Slack esté al frente.

## Claude Code como proveedor
`claude -p` persistente (Haiku, sin tools, stream-json), tres frases seguidas:

| Mensaje | Primer token | Total |
|---|---|---|
| 1 | 1.10 s | 1.37 s |
| 2 | 0.77 s | 1.01 s |
| 3 | 1.89 s | 2.14 s |

En frío (un proceso por petición): ~2 s.
