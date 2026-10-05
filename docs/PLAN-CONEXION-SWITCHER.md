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

### 4. Micrófono por presentador: auricular Bluetooth vinculado a cada cámara (idea del usuario, 2026-10-05)
- Cada presentador usa un auricular Bluetooth **vinculado a SU celular cámara**, no al switcher: los canales quedan
  separados solos (el audio de cada cámara = su presentador) y el corte automático por audio del switcher ya funciona
  con el nivel de cada cámara.
- Ventajas: el filtrado de ruido de los auriculares (beamforming) reduce que la voz de uno entre en el micrófono del
  otro → el corte automático acierta más; menos eco (micrófono a centímetros de la boca); **retorno al oído** del
  presentador por el mismo auricular (indicaciones del operador; ya existe en WHIP, falta en el modo switcher).
- Por qué no «izquierdo = cámara 1, derecho = cámara 2» con unos auriculares en el switcher: el Bluetooth de voz es
  **un solo canal mono** (los TWS usan un micrófono o los mezclan) y Android admite **un** micrófono Bluetooth a la vez.
- A resolver: calidad de llamada (16 kHz; 32 kHz con LE Audio) — perfecta para disparar el corte, justa para el aire;
  **retraso del Bluetooth (~100–200 ms)** a medir y compensar; selector «Micrófono: celular / auricular Bluetooth»
  en la app de cámara con el nombre del equipo y un medidor de nivel; batería en sesiones largas.
- Alternativa de calidad broadcast: kit inalámbrico de dos transmisores (DJI Mic, Rode Wireless GO, Hollyland Lark)
  en modo estéreo separado (TX1 izquierda / TX2 derecha) o interfaz USB de 2–4 canales enchufada al switcher:
  canal → cámara asignable en pantalla. Sirve igual en el modo Cámara → SAMBA.

### 5. Latencia entre fuentes: alinear todo a la más lenta
- Hoy la cámara local del switcher llega casi sin retraso y las remotas con ~100–300 ms (codificación + red + buffer
  de WebRTC + decodificación): al cortar entre local y remota el tiempo salta, en dividida/PiP las imágenes quedan
  desfasadas, y el micrófono del switcher (instantáneo) no coincide con los labios de una cámara remota. (El audio de
  cada cámara viaja sincronizado con SU video.)
- Solución automática:
  1. **Medir en vivo la latencia de cada fuente**: hora de captura de cada cuadro (RTCP Sender Reports) con los
     relojes de los celulares sincronizados por un intercambio tipo NTP en el canal de la sala.
  2. **Retrasar las fuentes rápidas** (cámara local, micrófono del switcher, cámaras más cercanas) hasta la más lenta
     + un margen; para la cámara local, unos cuadros guardados en la GPU.
  3. Igualar las remotas entre sí con el mismo objetivo de buffer de WebRTC (jitterBufferTarget).
  4. **Tope** (~500 ms): si una cámara viene más lenta, avisar en vez de retrasar todo el programa.
  5. El **retorno** al presentador va sin retraso (conversación natural con el operador).
- Costo: el programa sale con la latencia de la cámara más lenta (~0,2–0,3 s): no se nota en una emisión; el desfase
  entre cámaras sí, y desaparece. Mismo criterio para el retraso del micrófono Bluetooth (punto 4).

#### 5b. Cómo medir el retraso de cada cámara (idea del usuario: «pip» con parpadeo + sonido, 2026-10-05)
Una claqueta (destello + pitido que todas captan) da el retraso exacto de punta a punta. El destello tiene un
problema práctico: la cámara tiene que estar mirando adonde ocurre (la pantalla del celular cámara mira al operador,
no a la lente). Combinación más eficiente:
1. **Continua e invisible — marcas de tiempo**: cada cuadro WebRTC lleva su hora de captura; con los relojes
   sincronizados, el switcher mide red + buffer de cada cámara todo el tiempo y se adapta si la red cambia.
2. **Retraso del sensor medido en la propia cámara, sin destello**: Camera2 da el instante de exposición de cada
   cuadro (`SENSOR_TIMESTAMP`); la cámara lo compara con cuándo lo entrega al encoder (30–120 ms según el modelo) y
   lo informa por el canal de control. Mide lo mismo que el destello, sola y siempre.
3. **«Pip» sonoro para el audio** (la idea del usuario, donde sí es la mejor): el switcher emite un pitido corto al
   conectar o con un botón «Sincronizar»; cada cámara lo detecta **en su micrófono antes de comprimir** y avisa a qué
   hora lo escuchó → retraso de audio de cada cámara, auricular Bluetooth incluido. El sonido llega aunque las cámaras
   no miren al switcher.
4. **Verificación de fondo sin pitido**: correlación de las voces que captan los distintos micrófonos (como los
   editores de video para sincronizar cámaras) → detecta si algo se desacomoda durante la emisión.
Relación: SAMBA (PC) tiene pendiente la prueba de «palmada» de sincronía (T1–T10): mismo sistema en los dos lados.

### 6. Cámara USB (en el switcher o en un celular cámara)
- Android trae soporte de cámaras USB (UVC, «external camera») en Camera2 desde Android 9, pero muchos fabricantes lo
  desactivan → **detectarlo** (`CameraCharacteristics.LENS_FACING_EXTERNAL`) y, si no está, leer la cámara como
  dispositivo USB con una librería UVC (modo host).
- Usos: una cámara de mejor calidad o una **capturadora HDMI USB** (cámara de video, consola, PC) como fuente.
- A medir: formatos (MJPEG / YUY2 / H.264 por USB), resolución y fps reales, consumo de batería del USB, latencia
  (entra como fuente local: casi cero → mismo alineado del punto 5).

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
