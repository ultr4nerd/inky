# Inky — Especificación de la Fase 1

> Estado: borrador para revisión · 2026-11-11

## Qué es

Inky es una herramienta de escritura asistida por IA para macOS, open source. Corrige y mejora lo que escribes en cualquier app (prioridad: Slack de escritorio), te **explica** cada corrección y usa el proveedor de IA que ya pagas (Claude Code, Codex, Ollama, API key) en lugar de cobrar una suscripción.

## Principios

1. **Fluido antes que completo.** El panel aparece al instante y el texto llega en streaming. Si algo tarda, se nota que está trabajando.
2. **Nunca romper el mensaje.** Se aplican solo los fragmentos que cambian; menciones, emojis y formato no se tocan.
3. **Nada sale de tu Mac sin que lo pidas.** En la Fase 1 solo se envía texto al pulsar el atajo.
4. **El proveedor es intercambiable.** Ninguno es especial; si uno se rompe, se cambia en Ajustes.
5. **Aprender, no solo corregir.** Cada cambio lleva una explicación de una línea.

## Alcance de la Fase 1

### Incluye
- App de barra de menús (sin icono en el Dock).
- Atajo global (por defecto `⌃⌥Space`, configurable).
- Panel flotante con diff, explicaciones y tono.
- Tres modos: **Corregir**, **Natural** (que suene nativo), **Traducir** (es↔en).
- Aplicación por fragmentos en Slack y apps con Accesibilidad; respaldo por portapapeles en el resto.
- Proveedores: Claude Code (`claude -p` persistente), Codex (`codex exec`), endpoint compatible con OpenAI (Ollama, LM Studio, API key).
- Ajustes: atajo, proveedor y modelo, idioma de las explicaciones (en/es), tono por app.

### No incluye (fases siguientes)
- Revisión en vivo / subrayado (Fase 2, Slack nativo).
- Extensión de Chrome (Fase 3).
- Actualizaciones automáticas, distribución notarizada.

## Flujo principal

1. Escribes en Slack. Antes de enviar, pulsas `⌃⌥Space`.
2. Inky lee el campo enfocado:
   - **Sin selección** → todo el contenido del campo.
   - **Con selección** → solo la selección.
3. Aparece el panel anclado al campo de texto (o al cursor del ratón si no hay posición), con spinner y el texto llegando en streaming.
4. El panel muestra:
   - El texto con los cambios marcados (diff por palabras).
   - Lista de cambios: `in the meeting → at the meeting — con eventos se usa "at"`.
   - Encabezado: modo · tono · proveedor (`Corregir · Slack: casual-profesional · Claude Haiku`).
5. Teclas:
   | Tecla | Acción |
   |---|---|
   | `Enter` | Aplicar todos los cambios |
   | `Esc` | Cerrar sin cambios |
   | `Tab` / `⇧Tab` | Cambiar de modo (re-ejecuta) |
   | `⌘E` | Mostrar/ocultar explicaciones |
   | `⌘C` | Copiar el resultado sin aplicar |
6. Al aplicar, el panel se cierra y el foco vuelve a Slack.
7. Si no hay cambios: "Se ve bien ✓" y se cierra solo.

## Arquitectura

```
Inky.app (Swift 6, AppKit)
├── HotkeyService           atajo global
├── TextAccess              leer/escribir el campo enfocado
│   ├── AXTextAccess        Accesibilidad (Slack, apps nativas)
│   └── ClipboardTextAccess respaldo ⌘A/⌘C/⌘V con restauración
├── PanelController         NSPanel flotante + vista SwiftUI
├── InkyCore (librería, testeable)
│   ├── Providers           ClaudeCodeProvider, CodexProvider, OpenAICompatibleProvider
│   ├── PromptBuilder       modo + tono + idioma de explicaciones
│   ├── CorrectionParser    JSON → [Edit]
│   └── EditPlanner         [Edit] → rangos a reemplazar, evitando menciones
└── Settings                UserDefaults
```

### Lectura y escritura en Slack (validado, ver `docs/research/slack-accessibility.md`)
- Activar `AXManualAccessibility = true` en el proceso de Slack al iniciar Inky y cuando Slack se lance.
- **Leer:** `kAXFocusedUIElement` → `AXTextArea` → `AXValue`, `AXSelectedTextRange`.
- **Menciones:** son `AXStaticText` hijos separados; sus rangos se marcan como intocables.
- **Escribir:** por cada cambio, de atrás hacia adelante (para no desplazar índices):
  1. `AXSelectedTextRange = rango`
  2. Teclear el reemplazo con `CGEvent` unicode (en trozos de ≤ 20 caracteres).
- No funcionan en Slack: `AXReplaceRangeWithText` (−25212) ni asignar `AXSelectedText` (se ignora).
- Verificar tras aplicar: releer `AXValue` y comparar con el resultado esperado; si difiere, avisar y ofrecer copiar.

### Contrato con el modelo
El modelo responde **solo JSON**:

```json
{
  "edits": [
    { "original": "this are", "replacement": "this is",
      "explanation": "Con 'this' (singular) se usa 'is'." }
  ],
  "corrected": "hey @name this is a test for the meeting"
}
```

- `original` debe aparecer literal en el texto; el `EditPlanner` localiza su rango (la ocurrencia más cercana a la posición esperada) y descarta cambios que toquen una mención.
- Si el JSON no parsea, se muestra `corrected` como texto plano con opción de copiar.
- Las menciones se envían al modelo como marcadores (`⟦m1⟧`) para que no las altere.

### Proveedores
| Proveedor | Cómo | Notas |
|---|---|---|
| Claude Code | Proceso `claude -p` persistente, `--input-format stream-json --output-format stream-json --include-partial-messages`, sin tools/MCP/settings, `--system-prompt` propio | ~1 s por corrección (medido). Reiniciar el proceso cada N peticiones para no acumular contexto. |
| Codex | `codex exec` por petición | Latencia por medir. |
| OpenAI-compatible | HTTP streaming a `baseURL` + `model` + API key opcional | Ollama, LM Studio, OpenAI, OpenRouter. |

El modelo por defecto es el más rápido del proveedor (Haiku en Claude).

### Tonos por app (por defecto)
| App (bundle id) | Tono |
|---|---|
| Slack | casual-profesional |
| Mail, Outlook | formal |
| Otras | neutro |

## Privacidad
- Solo se envía el texto del campo al pulsar el atajo.
- Historial local en la Fase 1, **apagado por defecto**: guarda original, resultado y explicaciones en `~/Library/Application Support/Inky/` para repasarlas. Se puede borrar desde Ajustes.
- No se lee nada de campos seguros (`AXSecureTextField`).

## Firma y permisos
- Desarrollo: firmar cada build con la misma identidad (Apple Development) para que macOS no revoque el permiso de Accesibilidad.
- Distribución (más adelante): certificado **Developer ID Application** + notarización. Hoy no hay uno en el llavero.

## Criterios de éxito de la Fase 1
- Desde pulsar el atajo hasta ver el primer texto: < 1.5 s (p50) con Claude Haiku.
- En Slack, aplicar nunca borra ni convierte una mención en texto.
- `⌘Z` en Slack deshace la corrección.
- Funciona en Slack, Mail, Notes y Chrome (con respaldo de portapapeles).

## Decisiones
1. Licencia: MIT.
2. Aceptar/rechazar cambios individuales: después de la Fase 1 (en la Fase 1 se aplica todo o nada).
3. Historial local: en la Fase 1, apagado por defecto.
