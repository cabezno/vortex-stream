# Samba Air — Referencia Definitiva de Transportes

**Revisado desde código fuente: 2026-06-13**
**Versión de la app: 0.6.0**
**Ubicación canónica: `D:\Desktop\SOFTWARE\STREAM\vortexcam-app\`**

> Este documento existe para que no se vuelva a re-descubrir lo mismo cada sesión.
> Verificado leyendo directamente los archivos fuente. No asume nada.

---

## 1. Arquitectura General

```
[Android App — Samba Air]                    [VortexEngine — STREAM/MEZCAL]
                                             
 Flutter (Dart) UI                           C++/Vulkan engine
     │                                            │
     ├── MethodChannel "com.vortex.vortexcam/native" ── VortexCamPlugin.kt
     │       SRT, SBL, RTMP, flip, camera            │
     ├── MethodChannel "com.vortex.vortexcam/omt" ─── OmtStreamPlugin.kt
     │       OMT (OpenMediaTransport)                 │
     └── WebRTC (flutter_webrtc) ─────────────────── WHIP HTTP endpoint
                                                      │
                                             ┌────────┴────────┐
                                             │  phonecam panel │
                                             │  srt_source.cpp │  SRT/TCP port 8890
                                             │  sbl_source.cpp │  SBL UDP  port 8890
                                             │  whip_server    │  HTTP     port 8080
                                             │  (OMT: FALTA)   │
                                             └─────────────────┘
```

### Puertos del engine (valores por defecto confirmados)

| Servicio             | Puerto | Protocolo | Fuente confirmada                          |
|----------------------|--------|-----------|--------------------------------------------|
| WHIP HTTP            | 8080   | TCP HTTP  | `VCFG.phoneCam.whipPort = 8080`            |
| SRT cam listener     | **8890** | **TCP** (no real SRT) | `CfgPhoneCam::srtPort = 8890` (vortex_config.hpp:168) |
| SBL v3 listener      | **8890** | UDP     | `SblConfig::port = 8890` (sbl_source.hpp)  |
| Remote/API           | 9000   | TCP       | `VCFG.remote.port = 9000`                  |

**Importante:** El engine tiene un guard en `app.cpp:264-267` que detecta colisión entre srtPort y remote.port y fuerza srtPort=8890. El default ya es 8890, esto solo protege configs migradas.

---

## 2. Transporte SRT

### Estado: FUNCIONAL (con caveats de puerto y flip)

### Flujo real (verificado en código fuente)

```
App Kotlin (VortexCamPlugin.kt)          Engine C++ (srt_source.cpp)
                                          
Camera2 → MediaCodec H.264               tcpFallbackThread() activo
    │                                         (SOCK_STREAM TCP)
    ▼                                             │
SrtSocket (java.net.Socket TCP)  ───────────────►│ port 8890
    │  MPEG-TS 188-byte packets                  │ processTSPacket()
    │  PAT cada 15 paquetes                      │     ▼
    │                                        demux PIDs
    │                                        H.264 (PID 0x1B) → H264Decoder ✓
    │                                        H.265 (PID 0x24) → DESCARTADO ✗
    │                                        AAC   (PID 0x0F/0x11) → AudioDecoder ✓
```

**SrtSocket NO es SRT/UDP real.** Es `java.net.Socket` (TCP puro). El engine lo acepta via `tcpFallbackThread()` en `srt_source.cpp:869-977`, que corre en listener mode (`cfg_.listenerMode = true` para phonecam).

### Bugs confirmados en SRT

#### B6 — Puerto incorrecto en fallback y defaults (MEDIO)

| Archivo | Línea | Valor actual | Correcto |
|---------|-------|-------------|---------|
| `srt_connection_service.dart` | 29 | `_enginePort = 9000` | 8890 |
| `srt_connection_service.dart` | 87 | `fallbackPort = 9000` | 8890 |
| `connection_config.dart` | ~100 | `port = 9000` (QR default) | 8890 |
| `connection_config.dart` | ~221 | `fromSrtIp(ip, {int port = 9000})` | 8890 |

Si el QR incluye el puerto explícito (correcto: 8890), no hay problema. Si el usuario conecta manualmente sin QR o el QR no trae puerto, llega al puerto 9000 (RemoteServer, no SRT) y falla.

**`connectTo()` tiene default correcto** (`port = 8890`, línea 119). `_connectSrt()` en main.dart llama `srt.connectTo(host, port: srtCfg.port)` donde `srtCfg.port` viene del QR.

#### B5 — Flip de cámara SRT rompe la conexión (MEDIO)

`main.dart:~567`:
```dart
// ACTUAL (ROTO):
case Transport.srt:
  await context.read<SrtConnectionService>().connectTo('', port: 0);
  // ↑ Intenta conectar a IP vacía:puerto 0 → excepción → corta streaming

// CORRECTO:
case Transport.srt:
  await MethodChannel('com.vortex.vortexcam/native').invokeMethod('flipCamera');
```

El native `flipCamera()` (VortexCamPlugin.kt:220-241) está completamente implementado: cierra la cámara, cambia facing, reabre con la misma superficie del encoder. Solo hay que llamarlo correctamente.

#### B7 — Codec default peligroso en native (BAJO — neutralizado por Dart)

`VortexCamPlugin.kt:350`:
```kotlin
val codec = call.argument<String>("codec") ?: "hevc"
```
Dart siempre envía `'codec': 'h264'` (`srt_connection_service.dart:147`), por lo que el default "hevc" nunca se activa. El engine descarta H.265 silenciosamente. Dejar como documentación de riesgo.

### Flujo de conexión SRT exitoso (main.dart → `_connectSrt()`)

```
_connectSrt()
  ├── srt.startCamera(frontCamera: ...) → invokeMethod('startCamera', {'facing': 'front'/'back'})
  │       native: Camera2 init + MediaCodec + retorna Map{'textureId': id} ✓
  ├── srt.connectTo(host, port: srtCfg.port) → _startStreaming()
  │       invokeMethod('startSrt', {engineIp, enginePort, width, height, bitrateBps, codec:'h264', ...})
  │       native: SrtSocket TCP → conecta a engine:8890
  └── stats polling: invokeMethod('getStats') → {bitrateMbps, rttMs} ✓
```

---

## 3. Transporte SBL (Samba Broadcast Link v3)

### Estado: PARCIALMENTE ROTO — bugs críticos en Dart service

### Flujo real (verificado)

```
App Dart (SblConnectionService.dart)
  ↓ RawDatagramSocket bind(0.0.0.0, puerto_random_X)
  ↓ sendHello() [UDP → engine:8890]  ← Dart Hello desde puerto X
  ↓ waitHelloAck() en socket X

App Kotlin native (VortexCamPlugin.kt / SBL internal)
  ↓ startSbl() → setupEncoder() → sendSblHello() [UDP → engine:8890] ← SEGUNDO Hello desde puerto Y
  ↓ drainToSbl() → video UDP desde puerto Y

Engine (sbl_source.cpp)
  ↓ networkLoop() UDP
  ↓ Hello #1 (puerto X): handleHello() → sender_={IP:X} → HelloAck → X → state=Connected
  ↓ Hello #2 (puerto Y): handleHello() → sender_={IP:Y} → HelloAck → Y → state=Connected (reset)
  ↓ Video data (puerto Y): procesado ✓ (sender_.known=true desde Hello #2)
```

**El video SBL en teoría puede llegar** porque el segundo Hello "gana" y el engine envía HelloAck al puerto nativo Y, que es de donde viene el video. Pero el estado en Dart queda inconsistente.

### handleHello() en engine — comportamiento confirmado

`sbl_source.cpp:512-561`:
- En cada Hello recibido: actualiza `sender_.ip/port` con el remitente más reciente
- Envía HelloAck al remitente actual
- Mueve estado a `Handshaking` → `Connected` en la misma llamada
- **No rechaza Hellos duplicados** — cada Hello fuerza re-handshake completo

### Bugs confirmados en SBL

#### B1 — `startCamera()` — argumento incorrecto + return type incorrecto (CRÍTICO)

`sbl_connection_service.dart:93-97`:
```dart
// ACTUAL (ROTO):
final texId = await _channel.invokeMethod<int>('startSrtCamera', {
  'frontCamera': frontCamera,  // native lee 'facing' (String) → siempre usa "back"
});
_textureId = texId;            // native retorna Map, <int> lo convierte a null → sin preview

// CORRECTO:
final result = await _channel.invokeMethod<Map>('startSrtCamera', {
  'facing': frontCamera ? 'front' : 'back',
});
_textureId = result?['textureId'] as int?;
```

Nota: `'startSrtCamera'` es alias de `'startCamera'` en el dispatch nativo (VortexCamPlugin.kt). Funciona.

#### B2 — `stop()` llama método inexistente (CRÍTICO)

`sbl_connection_service.dart:358`:
```dart
// ACTUAL (ROTO):
await _channel.invokeMethod('stopSblStream').catchError((_) {});
// 'stopSblStream' NO existe → notImplemented() → catchError silencia → native nunca para

// CORRECTO:
await _channel.invokeMethod('stopSbl').catchError((_) {});
```

Dispatch nativo confirma: `"stopSbl"` → `stopStream()` ✓. `"stopSblStream"` no existe.

#### B3 — Stats llama método incorrecto (MEDIO)

`sbl_connection_service.dart:160`:
```dart
// ACTUAL (ROTO):
final stats = await _channel.invokeMethod<Map>('getSrtStats');
// 'getSrtStats' NO existe → notImplemented() → stats siempre null/0

// CORRECTO:
final stats = await _channel.invokeMethod<Map>('getSblStats');
```

Dispatch nativo confirma: `"getSblStats"` → `{bitrateMbps}` ✓. `"getSrtStats"` no existe.

#### B4 — `connect()` no pasa parámetros de video (MEDIO)

`sbl_connection_service.dart:148`:
```dart
// ACTUAL:
await _channel.invokeMethod('startSblStream', {
  'host':       host,
  'port':       port,
  'sourceName': sourceName,
  // FALTAN: 'width', 'height', 'bitrateBps'
});
// native startSbl() usa defaults: 1280×720, 8 Mbps

// PROBLEMA EXTRA: configure() llama 'configureSrt' que es no-op en native
// Los valores de configure() se guardan en _width/_height/_bitrateBps pero nunca llegan a native
```

Fix: guardar valores de `configure()` en campos y pasarlos en `connect()`.

#### B8 — Doble Hello (MEDIO)

Como se describe arriba: Dart envía Hello desde socket propio, luego native también envía Hello desde su socket. El engine re-hace el handshake dos veces. El resultado final puede funcionar (native gana) pero es frágil y poco determinista.

**Fix recomendado:** Eliminar el Hello del lado Dart. Dejar que native maneje el handshake completo. Dart solo llama `startSblStream` y espera.

Alternativa más simple: eliminar `sendSblHello()` de `startSbl()` en native, ya que Dart ya lo envió.

### Dispatch nativo SBL (VortexCamPlugin.kt) — tabla confirmada

```
"startSblStream" → startSbl(call, result)   // alias
"startSbl"       → startSbl(call, result)
"stopSbl"        → stopStream()             ← CORRECTO (no "stopSblStream")
"getSblStats"    → {bitrateMbps}            ← CORRECTO (no "getSrtStats")
"startSrtCamera" → startCamera(call, result) // alias (retorna Map{"textureId": id})
```

---

## 4. Transporte WHIP

### Estado: FUNCIONAL (verificado en sesiones anteriores)

Flujo: Flutter WebRTC (flutter_webrtc) → H.264 WebRTC → libdatachannel en engine → frame display.

- Puerto engine: 8080 (`VCFG.phoneCam.whipPort`)
- QR incluye URL completa: `{"whip": {"url": "http://IP:8080/whip/"}}`
- Requiere que libdatachannel esté compilado en el engine

### Bug menor B10 — QR validator strict

`connection_config.dart:146`:
```dart
// ACTUAL:
if (j['app'] != 'vortexcam') return null;

// PROBLEMA: samba-desktop emite "sambacam" → QR no parsea
// FIX si se necesita compatibilidad:
if (j['app'] != 'vortexcam' && j['app'] != 'sambacam') return null;
```

---

## 5. Transporte RTMP

### Estado: FUNCIONAL con implementación frágil

Kotlin puro en `RtmpClient.kt`. No usa librtmp. Implementa el handshake RTMP manualmente.

#### B9 — `readAck()` frágil (MEDIO)

```kotlin
// ACTUAL:
Thread.sleep(50)
while (input.available() > 0) { /* read */ }

// PROBLEMA: 50ms puede no ser suficiente en WiFi cargado
// CORRECTO: loop con timeout real o usar DataInputStream.readFully()
```

En práctica funciona en redes locales. Puede fallar en latencias altas.

---

## 6. Transporte OMT (Open Media Transport)

### Estado: NO FUNCIONAL — doble bloqueo

1. **Engine no tiene receptor**: VortexEngine STREAM no tiene código de recepción OMT. Sería un proyecto de semanas implementarlo.
2. **APK no tiene libvmx**: `OmtStreamPlugin.kt` carga `libvmx` y `libvmxjni` en static init. Si no carga (siempre en builds actuales), `nativeAvailable = false`. Todos los llamados retornan `"OMT_UNAVAILABLE"`.

El teléfono actúa como servidor TCP (`ServerSocket`) y el engine debería conectarse como cliente. La inversión de roles hace más difícil la integración.

**Recomendación:** Ocultar OMT en la UI hasta que haya implementación de engine.

---

## 7. `connect_screen.dart` — Pantalla zombie

`lib/screens/connect_screen.dart` es código muerto. La UI activa es `main.dart::_HomePage._buildConnectView()`.

`ConnectScreen` solo muestra SRT + WHIP (sin SBL/RTMP/OMT). No está en ninguna ruta de navegación activa desde main.dart. En SRT, hace `cam.initialize()` (WebRTC CameraService) antes de `srt.connectTo()` sin llamar `srt.startCamera()` — esto sería un bug si la pantalla fuera usada.

---

## 8. VortexCamPlugin.kt — Dispatch Table Completo

Canal: `com.vortex.vortexcam/native`

```
Método              │ Handler                │ Notas
────────────────────┼────────────────────────┼───────────────────────────────────
"startCamera"       │ startCamera()          │ Lee 'facing' (String), retorna Map{"textureId": Long}
"startSrtCamera"    │ startCamera()          │ Alias ✓
"stopCamera"        │ stopCamera()           │
"flipCamera"        │ flipCamera()           │ Cierra + reabre cámara con mismo encoder surface
"setTorch"          │ setTorch(on)           │ Lee 'on' (Boolean)
"startSrt"          │ startSrt()             │ Lee engineIp, enginePort, width, height, bitrateBps, codec
"stopSrt"           │ stopStream()           │
"startRtmp"         │ startRtmp()            │
"stopRtmp"          │ stopStream()           │
"getStats"          │ {bitrateMbps, rttMs}   │ Para SRT/RTMP
"startSbl"          │ startSbl()             │ Lee host, port, sourceName, width, height, bitrateBps
"startSblStream"    │ startSbl()             │ Alias ✓
"stopSbl"           │ stopStream()           │ (NO "stopSblStream")
"getSblStats"       │ {bitrateMbps}          │ (NO "getSrtStats")
"configureSrt"      │ result.success(null)   │ NO-OP — no guarda nada
"discoverSrt"       │ discoverSrt()          │ mDNS browse "_srt._udp.local", timeout en ms
"connectWifi"       │ connectWifi()          │
else                │ result.notImplemented()│
```

---

## 9. `startCamera()` en native — detalles críticos

`VortexCamPlugin.kt`:
- Lee `call.argument<String>("facing") ?: "back"` → acepta "front" o "back"
- Crea `flutterTexture` via `textureRegistry.createSurfaceTexture()`
- Configura Camera2 con `encoderSurface` (para el encoder)
- Retorna `mapOf("textureId" to flutterTexture!!.id())` — **siempre Map, nunca Int**
- `stopCamera()` libera la textura y cierra Camera2

---

## 10. Plan de fixes — orden de implementación

Todos los fixes son en Dart/Kotlin. No requieren recompilar el engine C++.

### Sprint 1: SBL funcional (1 archivo: `sbl_connection_service.dart`)

| ID | Fix | Impacto |
|----|-----|---------|
| B1 | `startCamera()`: `'frontCamera'→'facing'`, retorno `<int>→<Map>` | Preview SBL funciona |
| B2 | `stop()`: `'stopSblStream'→'stopSbl'` | Stop SBL funciona |
| B3 | Stats: `'getSrtStats'→'getSblStats'` | Stats SBL funciona |
| B4 | `connect()`: pasar width/height/bitrateBps | Resolución/bitrate configurables |
| B8 | Eliminar doble Hello | Handshake limpio |

### Sprint 2: SRT fixes (2 archivos)

| ID | Fix | Impacto |
|----|-----|---------|
| B5 | `main.dart` flip SRT: `connectTo('',0)→invokeMethod('flipCamera')` | Flip no corta streaming |
| B6 | `srt_connection_service.dart`: fallbackPort 9000→8890; `connection_config.dart`: defaults 9000→8890 | Manual connect funciona |

### Sprint 3: Calidad

| ID | Fix | Impacto |
|----|-----|---------|
| B7 | `VortexCamPlugin.kt:350`: default codec "hevc"→"h264" | Seguridad defensiva |
| B9 | `RtmpClient.readAck()`: sleep+available → read loop real | RTMP en WiFi cargado |
| B10 | `connection_config.dart`: aceptar "sambacam" en QR | Compatibilidad con samba-desktop QR |

### Decisión pendiente

- **OMT**: ocultar en UI vs implementar engine receiver (meses de trabajo)

---

## 11. Flujo de `_connect()` en main.dart

```
main.dart::_connect()
├── 40s master watchdog timeout
├── Transport.sbl  → _connectSbl()
│     ├── sbl.configure(width, height, bitrateBps)  ← NO-OP en native
│     ├── sbl.startCamera(frontCamera)              ← B1: arg+retorno roto
│     └── sbl.connect(host, port, sourceName)       ← B4: falta video params; B8: doble Hello
├── Transport.omt  → _connectOmt()                  ← siempre falla (OMT_UNAVAILABLE)
├── Transport.srt  → _connectSrt()
│     ├── srt.startCamera(frontCamera)              ← OK ✓
│     └── srt.connectTo(host, port: srtCfg.port)   ← OK si port=8890 ✓
├── Transport.whip → _connectWhip()                 ← WebRTC, funciona ✓
└── Transport.rtmp → _connectRtmp()                 ← OK ✓

Prioridad desde QR: SBL > OMT > SRT > WHIP > RTMP
```

---

## 12. Rutas confirmadas funcionales vs rotas

| Transporte | App→Engine | Engine→Display | Estado |
|------------|-----------|----------------|--------|
| SRT (H.264) | TCP port 8890, MPEG-TS | tcpFallbackThread → H264Decoder | **FUNCIONA** si port=8890 y codec=h264 |
| WHIP (H.264) | WebRTC HTTP:8080 | libdatachannel | **FUNCIONA** |
| SBL video | UDP port 8890, SBL v3 | networkLoop → decoders | **PARCIALMENTE** — video puede llegar pero preview/stop/stats rotos en Dart |
| RTMP | Kotlin RTMP TCP | No (es push externo) | **FUNCIONA** con ACK frágil |
| OMT | N/A | N/A | **NO FUNCIONA** — engine sin receptor |
| SRT flip | — | — | **ROTO** — corta la conexión |
| SBL preview | — | Flutter Texture | **ROTO** — textureId siempre null |
| SBL stop | — | — | **ROTO** — native nunca para |
