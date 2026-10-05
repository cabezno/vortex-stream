# Plan — conexión cámaras ↔ switcher y calidad sin cortes

Fecha: 2026-10-05. Origen: pruebas con tres celulares (Xiaomi, Mi A3, Galaxy A10) del 2026-10-04 y conversación con
el usuario. Estado: **planificado, sin empezar**. Nada de esto está implementado todavía.

## Principios (acordados con el usuario)

1. **Primero la conexión, después la calidad.** Mejorar el camino de red (salto único, banda, cercanía, red propia)
   rinde más que bajar la calidad. La adaptación de bitrate queda como red de seguridad.
2. **Nunca una caída de imagen al cortar de cámara**, ni al cambiar la calidad del stream o de la conexión.
3. **Medido en el celular, en el momento.** Nada fijado por modelo de teléfono (ver `DeviceCapabilities`).

## Lo que se midió (2026-10-04)

- El switcher recibe cada cámara a 1920×1080, 27–30 fps, 3,5–6 Mbps (H.264 por hardware, VP8 si el H.264 no arranca).
- Programa de salida: H.264 1920×1080 30 fps 6 Mbps + AAC 160 kbps (28,6–30,2 fps medidos en los tres como switcher).
- Hoy **todas** las cámaras llegan en alta (no hay capa baja aunque la UI dijera «1 Decode + N Low»): el A10 como
  switcher no pudo con dos cámaras 1080p (9–23 fps decodificados; su encoder 1080p rechazado por capacidad).
- Router de por medio: cada paquete cruza el aire dos veces (cámara → router → switcher) en el mismo canal.
- El Mi A3 pierde 6–15 % de paquetes en el Wi-Fi de la casa aun solo; dos cámaras 4K saturan el Wi-Fi.
- El encoder del Xiaomi soporta H.264/H.265 hasta 3840×2160 a 30 fps (2560×1440 a 60).

## Orden de trabajo propuesto

### 1. Red propia del switcher (hotspot local) — la mejora de red más grande
- El switcher levanta un **hotspot local** (`WifiManager.startLocalOnlyHotspot`, Android 8+): red solo interna, sin
  compartir internet. La SIM del switcher queda libre para la salida RTMP a la plataforma.
- Las credenciales (SSID, contraseña) van **dentro del QR** del switcher; la cámara ya sabe unirse a un Wi-Fi leído
  de un QR (`connectWifi` con `WifiNetworkSpecifier`, el mismo camino que el hotspot de SAMBA en la PC).
- Ganancia: un solo salto (casi el doble de capacidad útil), red sin tráfico ajeno, celulares cerca.
- A medir: **la banda que elige el sistema** (algunos Android arman el hotspot local en 2,4 GHz sin dejar elegir →
  detectarlo y avisar), cantidad de cámaras que aguanta, temperatura/batería del switcher, la subida real de la SIM
  (4G: 5–20 Mbps variables → la salida sigue necesitando bitrate adaptativo).

### 2. Modelo PGM / PVW — cortes sin caída de imagen
- Cada cámara manda **dos versiones a la vez**: baja (≈360p, para el multiview) y alta.
- El switcher decodifica en alta solo **PGM** (al aire) y **PVW** (la próxima); el resto en baja.
- **Corte = intercambio PVW ↔ PGM**, las dos ya decodificadas en alta: instantáneo, sin esperar un keyframe.
- Corte directo a una cámara que no estaba en PVW: sale al instante con su versión baja y se funde a la alta en
  < 0,5 s (pedido de keyframe inmediato). **Nunca negro.**
- Durante la emisión la salida solo cambia de **bitrate**, nunca de resolución (un cambio de SPS puede parpadear en
  el destino).
- Técnico: en WebRTC 1-a-1 (sin SFU) el simulcast clásico no sirve al receptor; dos pistas de video por cámara
  (dos transceivers) o un pedido explícito de capa. Probar con el Xiaomi y el Mi A3.

### 3. 4K en la cámara al aire
- La cámara al aire manda lo máximo que soporta **su** encoder (Xiaomi: 4K30), las demás en baja.
- Programa en 4K solo si el encoder del switcher lo soporta **y** el destino lo acepta (YouTube y SAMBA sí;
  Facebook y Twitch topan en 1080p).
- A verificar antes de prometer: el nivel H.264 que hoy anuncian las cámaras en el SDP es **4.1 (tope 1080p)**;
  4K pide 5.1 y no todos los encoders lo aceptan dentro de WebRTC.

## Evaluación de otros métodos de conexión entre celulares

| Método | Velocidad real aprox. | Alcance | ¿Video? | Para qué sirve | Comentarios |
|---|---|---|---|---|---|
| **Wi-Fi con router** (hoy) | 20–200 Mbps compartidos | casa/lugar | sí | todo | 2 saltos por paquete; depende del router y del tráfico ajeno |
| **Hotspot local del switcher** | 50–300 Mbps (5 GHz) | ~10–30 m | **sí** | red de cámaras | **recomendado (paso 1)**; la banda la decide el sistema |
| **Wi-Fi Direct** (P2P) | 50–250 Mbps | ~10–50 m | **sí** | red de cámaras | el switcher puede seguir en el Wi-Fi de la casa a la vez (STA+P2P en muchos equipos); pide permisos y a veces aceptar la invitación en pantalla; probar contra el hotspot |
| **Wi-Fi Aware** (NAN) | variable, hasta ~100 Mbps | ~10–30 m | posible | descubrimiento + datos sin AP | soportado solo en algunos equipos (detectar); sin red ni contraseña |
| **Ethernet por USB-C** (adaptador) | 100–940 Mbps estables | cable | **sí, el mejor** | instalaciones fijas | Android lo soporta solo; la app funciona igual (IP). Cero pérdidas, latencia mínima; un cable por cámara + switch de red. **Opción «pro»** |
| **USB directo celular-celular** | 100–400 Mbps | cable | sí | casos puntuales | modo accesorio/host, complejo, un cable por cámara; el Ethernet por USB-C es más simple |
| **Bluetooth clásico** | 1–2 Mbps | ~10 m | **no** | control, tally, audio de retorno (Opus) | no alcanza para video de calidad |
| **Bluetooth LE** (2M PHY) | 0,1–1,4 Mbps | ~10–30 m | **no** | descubrimiento, emparejar, tally, canal de control de respaldo si cae el Wi-Fi, nivel de batería | bajo consumo; buen complemento |
| **NFC** | 0,4 Mbps | 4 cm | **no** | **emparejar acercando los celulares** («tap to join»): pasa IP + credenciales del hotspot | alternativa al QR; Android Beam ya no existe (lectura con HCE/reader mode) |
| **UWB** | — | ~10 m | no | ubicación/distancia entre celulares | no es para datos |
| **Datos móviles por cámara** (4G/5G) | 5–50 Mbps subida, variable | internet | sí (SRT/WHIP) | cámaras lejos del switcher | latencia mayor; necesita un camino por internet (SAMBA/servidor) |
| **Salida combinada SIM + Wi-Fi** (bonding) | suma de enlaces | — | salida | la emisión del switcher a la plataforma | estilo LiveU / SRT bonding; para más adelante |

### Conclusión de la evaluación
- **Video entre celulares:** hotspot local del switcher o Wi-Fi Direct (inalámbrico), y **Ethernet por USB-C** cuando
  se puede cablear. Bluetooth y NFC no tienen ancho de banda para video.
- **Bluetooth LE:** como canal de **control y tally de respaldo** (si el Wi-Fi se corta, el switcher sigue sabiendo
  qué cámara está viva y le avisa si está al aire).
- **NFC:** como **emparejamiento por contacto**, alternativa al QR.
- **A comparar con mediciones** (mismos celulares, misma ubicación): router vs hotspot local vs Wi-Fi Direct —
  pérdida de paquetes, fps recibidos, pausas máximas, temperatura y batería del switcher en 30 min.
