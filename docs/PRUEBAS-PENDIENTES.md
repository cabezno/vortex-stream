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
