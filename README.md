# VortexCam — app de celular para VortexEngine

Convierte tu celular en una **cámara** para VortexEngine: escanea el QR que muestra
el motor (**Herramientas → Cámara de celular (WHIP)**), captura la cámara y la **publica
por WebRTC/WHIP** (H.264). Hecha en **Flutter** (Android + iOS).

> Contrato del protocolo: ver `VORTEXCAM_PROTOCOL.md` en el repo del motor.

---

## Obtener el APK (build en GitHub, sin instalar nada en la PC)

1. Creá un repo nuevo en GitHub (ej. `vortexcam`) y subí **el contenido de esta carpeta**
   (`vortexcam-app/`) como **raíz del repo** (el workflow vive en `.github/workflows/`).

   ```powershell
   cd D:\Desktop\SOFTWARE\STREAM\vortexcam-app
   git init
   git add .
   git commit -m "VortexCam app"
   git branch -M main
   git remote add origin https://github.com/<tu-usuario>/vortexcam.git
   git push -u origin main
   ```

2. En GitHub → pestaña **Actions** → el workflow **"Build VortexCam APK"** corre solo al
   pushear (o apretá **Run workflow**). Tarda ~3–5 min.

3. Cuando termine (✓), entrá al run → sección **Artifacts** → descargá **`vortexcam-apk`**
   → adentro está `app-release.apk`.

4. Pasá el APK al celular (cable / Drive / link) e instalalo. Android va a pedir permitir
   **"instalar apps de orígenes desconocidos"** → aceptá.

---

## Usar

1. En VortexEngine (PC): **Herramientas → Cámara de celular (WHIP)** → **Iniciar** → aparece el **QR**.
   - (Opcional) Si la PC es **hotspot**, primero escaneá el QR de WiFi para unir el cel a la red de la PC.
2. En el celular: abrí **VortexCam** → **Scan QR** → apuntá al QR de emparejamiento.
3. (Opcional) Poné un **nombre de cámara** (cada cel debe usar uno distinto).
4. **Go live** → la cámara aparece como fuente de escena en VortexEngine.

> Misma red en ambos lados. La URL WHIP es `http://` en LAN; el APK ya permite cleartext.

---

## Requisitos del lado PC
- VortexEngine compilado con **libdatachannel** (ver `CAMERA_SETUP.md`). Sin eso, el motor
  no recibe WebRTC en vivo (el panel avisa en amarillo).
- Firewall de Windows: permitir VortexEngine en el puerto WHIP (default **8080**).

## iOS
El código es cross-platform, pero generar/instalar el `.ipa` requiere **Xcode + cuenta de
Apple** (no se puede "descargar directo" como el APK). Para iOS conviene abrir el proyecto
en una Mac con `flutter build ios`, o usar TestFlight.

## Build local (alternativa, si tenés Flutter)
```bash
cd vortexcam-app
flutter create --platforms=android,ios --org com.vortexengine --project-name vortexcam .
flutter pub get
flutter build apk --release        # APK en build/app/outputs/flutter-apk/
```

---

## Estado (v0.1)
- [x] Escanear QR de emparejamiento (JSON del protocolo).
- [x] Cámara (frontal/trasera) + preview.
- [x] Publicar por **WHIP** (H.264 forzado por SDP munge), conectar/desconectar.
- [ ] Audio (Opus) — pendiente en motor y app.
- [ ] Modo **SRT** (LAN/máxima calidad) — pendiente.
- [ ] Canal de control (presets desde la PC) + talkback.
