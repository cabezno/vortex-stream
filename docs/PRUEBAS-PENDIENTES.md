# Pruebas pendientes — Samba Air (desarrollado 2026-10-06, sin probar)

Cada función tiene: **cómo probarla**, **qué tenés que ver** (la pista en pantalla) y **si falla, dónde mirar** (líneas
del registro: `adb logcat | grep <etiqueta>`). Al probar una, anotá el resultado (✅ / ❌ + qué pasó) al lado del título.

Para todas: instalar el APK del release `latest` (o el que compila Claude) en todos los celulares, el switcher en
horizontal. «Switcher» = el celular en modo Switcher; «cámara» = un celular en Cámara → Switcher (celular).

---

## P1. Vista previa y corte instantáneo (PGM/PVW)

**Cómo:** switcher + 2 o 3 cámaras unidas.
1. Tocá una miniatura del multiview que no esté al aire.
2. Tocá la misma miniatura otra vez (o el botón rojo **CORTE → nombre** abajo a la derecha del programa).
3. Repetí con la que quedó en verde: ida y vuelta entre dos cámaras.
4. Mantené apretada una tercera cámara (corte directo).

**Qué tenés que ver:**
- Paso 1: la miniatura con borde **verde** y «VISTA PREVIA»; en esa cámara, marco verde y «VISTA PREVIA»; su
  etiqueta abajo a la derecha de la miniatura pasa de **«360p · 15»** a **«1080p · 30»** en 3–6 s.
- Paso 2: el programa cambia **al instante, sin negro ni imagen borrosa**. La cámara nueva: marco rojo «EN EL AIRE».
  La anterior queda en verde (vista previa).
- Las cámaras que no están al aire ni en vista previa muestran «CALIDAD BAJA · 360p» y «360p · 15» en el multiview.
- Paso 4: corta al instante; puede verse algo borrosa menos de un segundo y se pone nítida. **Nunca negro.**
- Con 3 cámaras, en el switcher solo 2 miniaturas dicen 1080p.
- La barra de abajo del switcher dice «Preparada en vista previa: …», «Corte desde vista previa a …», «Corte directo a …».

**Si falla:** `[WebRtcPublisher] capa ALTA/BAJA` en la cámara (cada cambio de calidad); `[Subscriber STATS]` en el
switcher (`frameWidth x frameHeight`, `freezes`). Si una cámara no baja a 360p: no recibió `set_layer` (versión vieja
de la app en esa cámara).

## P2. 4K en la cámara al aire

**Necesita:** un switcher cuyo encoder haga 4K (el Xiaomi 24115RA8EG: sí) y una cámara que también (Xiaomi). Destino
YouTube o SAMBA (Facebook/Twitch no aceptan 4K).

**Cómo:** en el switcher, **Emitir** → «CALIDAD DEL PROGRAMA» → **4K** → Salir en vivo (a SAMBA o YouTube). Cortá a
la cámara que hace 4K y después a otra.

**Qué tenés que ver:**
- En el diálogo: con un celular que no puede, el botón 4K gris y el motivo («Este celular codifica hasta …»); con
  una URL de Facebook/Twitch, gris y «se emite en 1080p».
- Arriba a la derecha del programa: **«3840×2160 · 30 fps»**.
- La cámara al aire: «CALIDAD ALTA · 2160p»; en el multiview su miniatura «2160p · …». La de vista previa «1080p».
- La primera vez que una cámara pasa a 4K puede congelarse un instante (reabre la cámara); después, no.
- En SAMBA / YouTube el stream llega a 2160p.

**Si falla:** switcher `HardwareProgramEncoder` («Encoder refused 3840x2160 … → 1920x1080»: el hardware de video está
ocupado decodificando las cámaras; probar con menos cámaras). Cámara: `[WebRtcPublisher] cámara reabierta en 2160p` y
`capa ALTA: 2160p`. Si la cámara manda 2160p pero el switcher muestra 1080p: posible tope de nivel H.264 en WebRTC
(anotarlo, se arregla en el SDP).

## P3. Micrófono por presentador (auricular Bluetooth en la cámara)

**Necesita:** un auricular Bluetooth (de llamadas) vinculado al celular CÁMARA (no al switcher).

**Cómo:** cámara unida al switcher. Con el auricular apagado, prendelo: debe aparecer un aviso. Si no, tocá el
micrófono en la barra de abajo de la cámara → elegí el auricular. Hablá. Volvé a «Micrófono del celular».

**Qué tenés que ver:**
- Al prender el auricular: «Auricular conectado: <nombre>» con el botón «Usarlo como micrófono».
- En la barra de la cámara: el ícono de Bluetooth y el nombre del auricular, y la **barrita verde se mueve al hablar
  por el auricular** (y casi no se mueve si hablás lejos del celular).
- En el switcher, la miniatura de esa cámara: ícono de Bluetooth celeste + el nombre del auricular.
- Con dos cámaras, cada una con su auricular y el switcher en AUTO: corta a quien habla, y la voz del otro
  presentador casi no dispara su cámara.
- Al apagar el auricular, la cámara vuelve sola al micrófono del celular.

**Si falla:** `[Mic] usando: …` / `[Mic] no se pudo cambiar…` en la cámara. Si el auricular no aparece en la lista:
falta el permiso «Dispositivos cercanos» (Ajustes → Apps → Samba Air → Permisos).

## P4. Sincronía de cámaras (alinear a la más lenta + medir con pitidos)

**Cómo:** switcher con la **cámara local encendida** (ícono de cámara arriba) + 2 cámaras remotas, todas apuntando a
lo mismo (un reloj con segundero en pantalla, o alguien aplaudiendo). Botón **cronómetro** en la barra del switcher →
«Sincronía de cámaras».
1. Mirá la lista: cada cámara con «estimado N ms» y a la derecha «+N ms» (cuánto se la retrasa).
2. Tocá **Medir con pitidos** (silencio, cámaras a pocos metros). El switcher suena 3 pitidos.
3. Emití o grabá a SD 1 minuto en **Dividida**, con la cámara local de un lado y una remota del otro, aplaudiendo.
4. Repetí con «Alinear en el programa» apagado.

**Qué tenés que ver:**
- En las miniaturas: «≈150 ms» (estimado) y, después de medir, «180 ms» sin «≈». Ámbar si pasa de 500 ms.
- Al medir: «Medido: Cam1 180 ms · Cam2 210 ms» (si una no escuchó: «No se escucharon los pitidos en: …»).
- La cámara más lenta queda con «+0 ms», las demás con la diferencia; la cámara local con la mayor.
- En la grabación/emisión (paso 3): el aplauso se ve **a la vez en las dos mitades**; con la alineación apagada
  (paso 4), la cámara local va adelantada.
- Si la cámara local se ve igual adelantada: subir «Cámara de este celular: ajuste fino».
- Cortar desde vista previa no salta en el tiempo; un corte directo puede congelar un instante (≤ el retraso).

**Si falla:** `SyncProbe` en el registro del switcher («Cam: beeps heard 3/3 → 180 ms»); si oye 0/3, el audio de esa
cámara no llega al switcher (¿micrófono apagado?) o el switcher sonó muy bajo. `[SourceSync]` con el resultado.
`StudioSwitcher: Program primary … (delay N ms)` al cortar.

## P5. Cámara USB / capturadora HDMI

**Necesita:** una webcam USB o una capturadora HDMI→USB (UVC) y, si el celular es USB-C, un adaptador OTG.

**Cómo:** en la **cámara de Studio**, botón de cámara (al lado de girar) → lista. En el **switcher**, con la cámara
local encendida, el mismo botón arriba. Enchufá la cámara USB y tocá **buscar de nuevo** (flechas) en la lista.

**Qué tenés que ver:**
- La lista con «Trasera» (o «Trasera 1/2/3» si el celular tiene varias lentes), «Frontal» y, con la USB enchufada,
  **«Cámara USB / HDMI · hasta 1920x1080»**. Elegirla: la imagen pasa a la de la cámara USB (el botón queda celeste).
- Si el celular no soporta cámaras externas: el texto «Este celular no reconoce cámaras USB… su fabricante no activó
  esa función». (Es esperable en muchos; anotar cuáles sí: probar los 3.)
- En el switcher, la cámara local USB entra al programa (cortá a ella y mirá lo que se emite/graba).

**Si falla:** `DeviceCaps: listCameras` en el registro. Si la USB figura pero no abre: `FlutterWebRTCPlugin` (error
del capturer). Anotar el modelo de cámara USB.

## P6. Corte por audio como SAMBA (tabla micrófono → cámara, «Solo micrófono», planos especiales)

**Cómo:** switcher + 2 cámaras + 1 celular en **Cámara → Switcher (celular)** con **«Solo micrófono»** activado
(antes de unirse). En el switcher: ajustes de audio (ícono de deslizadores) → abajo «QUÉ MICRÓFONO CORTA A QUÉ
CÁMARA» y «PLANOS ESPECIALES». Switcher en **AUTO**.
1. Asigná el «Solo micrófono» a la Cámara 2; poné el micrófono de la Cámara 1 en «No corta».
2. Hablá cerca del «Solo micrófono». Después cerca de la Cámara 1.
3. «Cuando hablan varios» → una cámara (plano general). Hablen dos a la vez.
4. «Cuando nadie habla» → una cámara. Silencio unos segundos.
5. Emití/grabá: el «Solo micrófono» se escucha siempre en el programa.

**Qué tenés que ver:**
- El celular «Solo micrófono»: en vez de la cámara, un micrófono grande, «SOLO MICRÓFONO» y una barra que se mueve.
- En el switcher, una fila **MICRÓFONOS** bajo el multiview: el nombre, su nivel y «→ Cámara 2» (o «no corta»);
  NO aparece como miniatura de cámara.
- Paso 2: hablar en el «Solo micrófono» corta a la Cámara 2; hablar en la Cámara 1 no corta.
- Paso 3: corta al plano elegido para «varios»; paso 4: al de «nadie habla» después del «Tiempo para silencio».
- La barra de abajo del switcher dice por qué cortó («Orador activo en …», «Solapamiento…», «Silencio sostenido…»).

**Si falla:** el «Solo micrófono» no aparece en la fila: versión vieja de la app en ese celular. Si no se escucha en
el programa: `ProgramAudio: Mic-only phones in the mix: N` en el registro del switcher (N debe ser ≥ 1 al emitir).

## P7. Imagen derecha con el celular girado (SRT / SBL / RTMP a SAMBA)

**Cómo:** modo **Cámara → SAMBA (PC)** por SRT (y repetir con SBL). Transmitir con el celular apaisado normal; girarlo
180° (apaisado al revés) **sin cortar**; volver. Repetir con la cámara frontal.

**Qué tenés que ver:**
- En SAMBA la imagen siempre **derecha**, en las dos posiciones apaisadas, y se acomoda sola al girar (en < 1 s).
- La cámara frontal también derecha (antes podía estar al revés: se usaba la fórmula de la trasera).
- **En retrato, solo por SRT y con un SAMBA que ya lo soporte** (Mac desde `a277097`; Windows cuando `mac` entre a
  `main`): la imagen vertical, derecha, con barras al costado, y se acomoda sola al girar (en < 1 s). Con un SAMBA viejo
  o por SBL/RTMP sigue como antes (de lado).

**Si falla:** `RotatingRelay` / `Stream turned in pixels: 180°` en el registro del celular. «RotatingRelay unavailable»
= el celular no pudo armar el paso por GPU y va directo al codificador como antes. Retrato por SRT: en el log del
celular que llega a SAMBA (phone_logs) tiene que aparecer `[orientación] SRT → rotación 1 (90°)` al girar, y en el
log de SAMBA `phone orientation: rotation 1 (90°)`. Si está la del celular y no la de SAMBA, ese SAMBA es viejo.

## P8. Unirse a mano a la red propia (Android 9 o anterior, o conexión rechazada)

**Cómo:** switcher con «Red propia del switcher» activada. En una cámara con Android 9 o menos (o en cualquiera,
tocando «Cancelar» cuando Android pregunta si conectarse), escaneá el QR del switcher.

**Qué tenés que ver:**
- Un diálogo «Conectate a la red del switcher» con la red, la clave (botón para copiarla), «Abrir Ajustes de Wi-Fi»
  y, en Android ≤ 9, la explicación de por qué es a mano.
- Conectarse desde Ajustes, volver, «Ya me conecté» → entra a la sala sola.

**Si falla:** si entra a Ajustes pero al volver no se une: el celular se pasó de nuevo al Wi-Fi de la casa
(«sin internet»); elegir «mantener conectado» en el aviso de Android.

## P9. Emparejar acercando los celulares (NFC)

**Necesita:** NFC en el switcher (para «ser» la tarjeta) y en la cámara (para leerla), los dos con NFC activado.

**Cómo:** switcher abierto (con o sin red propia). En la cámara: Cámara → Switcher (celular), en la pantalla de unirse.
Apoyá la parte de atrás de la cámara contra la del switcher 1–2 segundos.

**Qué tenés que ver:**
- En la tarjeta de unirse de la cámara: «O acercá este celular al switcher» (celeste). Si NFC está apagado: «NFC
  apagado: tocá para activarlo…» → abre Ajustes; al volver, ya escucha.
- Al acercarlos: «Switcher detectado por NFC» y sigue sola como con el QR (se une a la red propia si la hay, entra a
  la sala).
- En un celular sin NFC no aparece la línea.

**Si falla:** `NfcPairing` en el registro de la cámara («read N chars from the switcher» / «not a Samba switcher» /
«read failed»). Si dice «not a Samba switcher»: el switcher no tiene la pantalla del switcher abierta o su NFC está
apagado. Probar distintas posiciones (la antena suele estar al centro o arriba).

## P10. La cámara se reconecta sola

**Cómo:** cámara unida al switcher. (a) En la cámara, apagá el Wi-Fi 5 s y volvé a prenderlo. (b) Cerrá el switcher
y volvé a abrirlo (modo Switcher). (c) Tocá la X de la cámara (salir a propósito).

**Qué tenés que ver:**
- (a) y (b): la cámara muestra «RECONECTANDO…» (ámbar) y «Se perdió el switcher: reconectando sola…» con un botón
  Salir; vuelve sola en segundos, con el mismo nombre en el multiview.
- (c): NO reintenta: vuelve a la tarjeta de unirse.

**Si falla:** `[Camera] sin conexión con el switcher: reintento en N s` en el registro de la cámara.
