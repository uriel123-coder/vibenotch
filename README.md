<div align="center">

<img src="docs/icon.png" width="128" alt="VibeNotch">

# VibeNotch

**El notch de tu Mac, convertido en centro de control para tus agentes de IA, tus archivos y tu día.**

Claude Code · app de Claude · Codex · Cursor · estante tipo Dropover · buscador de archivos · portapapeles y notas · convertidor y compresor de archivos · widgets

[![Build](https://github.com/uriel123-coder/vibenotch/actions/workflows/build.yml/badge.svg)](https://github.com/uriel123-coder/vibenotch/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/uriel123-coder/vibenotch?label=descargar)](https://github.com/uriel123-coder/vibenotch/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Apple Silicon + Intel](https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-555)
[![MIT](https://img.shields.io/badge/licencia-MIT-green)](LICENSE)

<img src="docs/screenshots/notch-3-agentes.png" width="760" alt="VibeNotch con agentes trabajando">

</div>

---

## Índice

- [¿Qué hace?](#qué-hace)
- [Instalación (1 minuto)](#instalación-1-minuto)
- [Primeros pasos](#primeros-pasos)
- [Conectar tus agentes](#conectar-tus-agentes)
- [Con notch o sin notch, una o varias pantallas](#con-notch-o-sin-notch-una-o-varias-pantallas)
- [Personalizar](#personalizar)
- [Consumo: RAM y batería](#consumo-ram-y-batería)
- [Atajos de teclado](#atajos-de-teclado)
- [Permisos](#permisos)
- [Privacidad](#privacidad)
- [Solución de problemas](#solución-de-problemas)
- [Desinstalar](#desinstalar)
- [Compilar desde el código](#compilar-desde-el-código)
- [English](#english)

---

## ¿Qué hace?

VibeNotch vive en el notch (o en una "isla" flotante si tu Mac no tiene notch). Pasa el mouse arriba al centro y se abre. Tiene 6 pestañas:

### ✨ Agentes: ve lo que hace tu IA sin cambiar de ventana

- **Claude Code, app de Claude, Codex y Cursor** en un solo lugar: qué proyecto, qué está haciendo ("Editando NotchView.swift", "Ejecutando npm test") y si ya terminó.
- **Responde preguntas desde el notch**: cuando Claude Code te hace preguntas de opción múltiple (o varias a la vez), aparecen ahí mismo. Tocas la opción, escribes "Otra respuesta" o eliges responder en la terminal.
- **Aprueba planes**: cuando Claude termina de planear, lees el plan y eliges **Aprobar** o **Seguir planeando**.
- **Permisos desde el notch**: cuando Claude Code pide permiso para correr un comando, respondes **Permitir** o **Rechazar** sin ir a la terminal.
- **Terminó, y qué hizo**: al acabar ves una palomita, el resumen de lo que respondió y cuánto tardó ("Listo: el formulario ya valida el correo · tardó 3 min"), con su sonido.
- **App de Claude (escritorio)**: sigue tus sesiones de Claude Code y Cowork dentro de la app. Ves cuándo trabaja, cuándo termina y cuándo te necesita, además de tus límites de uso, sin configurar nada.
- **Contexto y tokens** de cada sesión (barra de contexto usado y tokens totales).
- **Límites de tu plan**: ventana de 5 horas y semanal de Claude (Pro/Max) y de Codex (Plus/Pro), con cuándo se reinician.
- **Cada quien con su nombre**: lo que haces en Cursor sale como **Cursor**, aunque Cursor use por dentro los hooks de Claude Code. Si Cursor te hace una pregunta, el notch te avisa ("Cursor te pregunta") y la sesión queda en espera hasta que respondas en Cursor.
- **Se limpia sola**: lo que ya terminó desaparece de la lista a los 10 minutos (lo cambias en Ajustes → Agentes: 2 min, 30 min, 1 hora o nunca). También puedes tocar **Quitar terminados** o la ✕ de cada sesión.

<p align="center">
  <img src="docs/screenshots/notch-4b-pregunta.png" width="49%" alt="Claude te pregunta y respondes desde el notch">
  <img src="docs/screenshots/notch-4-permiso.png" width="49%" alt="Permiso de Claude desde el notch">
</p>

### 📥 Estante: arrastra y suelta, como Dropover

Arrastra cualquier archivo hacia el notch y se queda ahí guardado. Después lo arrastras a donde quieras (Mail, Slack, Finder, un prompt…). Desde el estante también puedes **reducir su peso**, juntarlo en un .zip, mandarlo por AirDrop, copiar rutas o abrirlo en Convertir.

**Sin notch no tienes que atinarle a nada:** en cuanto empiezas a arrastrar un archivo, aparece arriba al centro una zona verde que dice **"Suéltalo aquí"**.

### 🔍 Buscar: encuentra cualquier archivo por su nombre

Presiona **⌃⌥F** (o toca la lupa) y escribe parte del nombre: "factura", "contrato mayo", "logo". Los resultados salen mientras escribes.

- **Sin escribir nada** ves tus archivos más recientes (modificados o descargados hace poco).
- **Filtra** por Documentos, PDF, Imágenes, Videos o Carpetas.
- **Úsalo al momento**: ↩ lo abre, ⌘↩ lo muestra en Finder, o **arrástralo** directo a Mail, Slack, un prompt o el estante.
- **Rápido de verdad**: VibeNotch hace su propio índice de tus carpetas (Escritorio, Descargas, Documentos, iCloud Drive y las demás carpetas de tu usuario) en un par de segundos y en segundo plano. Después cada búsqueda tarda milisegundos, aunque Spotlight esté apagado. Se salta cosas que nadie busca a mano, como `node_modules`, carpetas `build` o miles de archivos de datos.

<p align="center">
  <img src="docs/screenshots/notch-6c-buscar.png" width="49%" alt="Buscar archivos">
  <img src="docs/screenshots/isla-6c-buscar.png" width="49%" alt="Buscar archivos en modo isla">
</p>

### 📋 Clips: historial, guardados y notas

- **Historial** de lo último que copiaste (texto, links, colores, imágenes y archivos), con buscador.
- **Guardados**: textos que pegas seguido, con atajo **⌃⌥1…9**.
- **Notas**: tarjetas de colores que se quedan ahí (tu correo, la clave del Wi-Fi, una dirección, un prompt). Un clic y quedan copiadas; también puedes arrastrarlas a cualquier app. Fija las que más usas para verlas en **Hoy**.
- Ignora automáticamente contraseñas de 1Password y apps que marcan el contenido como privado.
- Opcional: pegar directamente al elegir un clip o una nota.

<p align="center">
  <img src="docs/screenshots/notch-6b-notas.png" width="49%" alt="Notas para copiar">
  <img src="docs/screenshots/isla-5-estante.png" width="49%" alt="Estante">
</p>

### ☀️ Hoy: widgets que tú eliges

Activa, quita y ordena los que quieras en **Ajustes → Hoy**:

- **Música**: Spotify o Apple Music con controles.
- **Temporizador** y Pomodoro.
- **Notas fijadas**: un clic y las copias.
- **Batería** con tiempo restante (avisa al conectar el cargador y cuando queda poca).
- **Próximos eventos** de tu calendario, con aviso 5 minutos antes.
- **Sistema**: CPU, RAM y disco libre, y cuánta memoria usa VibeNotch.

<p align="center">
  <img src="docs/screenshots/notch-7-hoy.png" width="49%" alt="Hoy">
  <img src="docs/screenshots/isla-7b-hoy-sistema.png" width="49%" alt="Widget de sistema">
</p>

### 🪄 Convertir: 23 herramientas para archivos

Suelta archivos y elige qué hacer. Todo se hace en tu Mac, sin subir nada a internet.

| Tipo | Herramientas |
| --- | --- |
| Imagen | A JPG · A PNG · A HEIC · Comprimir · Reducir 50% · **Quitar fondo** · Girar · **Copiar texto (OCR)** · Quitar datos GPS/EXIF |
| PDF | Unir PDFs e imágenes en un PDF · Comprimir PDF · PDF a imágenes · Copiar texto |
| Video y audio | Comprimir video · A MP4 · **A GIF** · Sacar audio · A M4A |
| Archivos | **Reducir peso** (cualquier archivo) · Hacer .zip · Descomprimir · Copiar rutas · AirDrop |

**La compresión es de verdad.** Prueba varias versiones (calidad, tamaño, formato) y se queda con la mejor que pese al menos 15 % menos. Si tu archivo ya estaba optimizado, te lo dice ("Ya estaba optimizado") en vez de darte una copia igual o más pesada. Ejemplos reales: una foto PNG de 1.4 MB queda en 66 KB, y un fondo de pantalla HEIC de 26 MB en 1.5 MB. Los PDF escaneados se aligeran sin tocar los PDF con texto, y los GIF no se tocan para no perder la animación.

Te dice cuánto ahorraste ("1.4 MB → 66 KB · 95% menos") y eliges si el resultado se guarda en el estante o junto al original. Tu original nunca se modifica.

<p align="center">
  <img src="docs/screenshots/notch-8-convertir.png" width="70%" alt="Convertir">
</p>

---

## Instalación (1 minuto)

**Requisitos:** macOS 14 Sonoma o más nuevo. Funciona en Apple Silicon (M1, M2, M3, M4…) e Intel, con o sin notch.

### Opción 1: un comando (recomendada)

Abre la app **Terminal** (⌘ + Espacio, escribe "Terminal", Enter), pega esto y presiona Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/uriel123-coder/vibenotch/main/scripts/install.sh | bash
```

Descarga la última versión, la pone en **Aplicaciones** y la abre. Si ya la tenías, la actualiza. Es el mismo comando para actualizar.

### Opción 2: descargar el zip

1. Descarga **VibeNotch.zip** de [la última versión](https://github.com/uriel123-coder/vibenotch/releases/latest).
2. Descomprímelo y arrastra **VibeNotch.app** a **Aplicaciones**.
3. **La primera vez**, macOS la bloquea porque no viene de la App Store. Para abrirla:
   - Haz **clic derecho → Abrir → Abrir**, o
   - ve a **Ajustes del Sistema → Privacidad y seguridad**, baja hasta "VibeNotch se bloqueó…" y pulsa **Abrir de todos modos**.
   - Si dice que "está dañada", corre esto en Terminal y vuelve a abrirla:
     ```bash
     xattr -dr com.apple.quarantine /Applications/VibeNotch.app
     ```

> ¿Por qué pasa? VibeNotch es gratis y de código abierto, y no está firmada con un certificado de pago de Apple. Puedes revisar todo el código en este repo o compilarla tú mismo (opción 3).

### Opción 3: compilar desde el código

```bash
xcode-select --install          # solo si nunca lo instalaste (no hace falta Xcode completo)
git clone https://github.com/uriel123-coder/vibenotch.git
cd vibenotch
./build.sh install
```

---

## Primeros pasos

1. Al abrirla aparece un saludo en el notch y un ✨ en la barra de menús.
2. **Para abrir VibeNotch:** pasa el mouse arriba al centro de la pantalla, haz clic en ✨ o presiona **⌃⌥N**.
3. **Para ajustes:** el engrane ⚙️ dentro de VibeNotch, o clic derecho en ✨ → **Ajustes…** (⌘,).
4. Si usas Claude Code o Cursor: clic derecho en ✨ → **Conectar Claude Code** / **Conectar Cursor**. Codex y la app de Claude se detectan solos.
5. Se abre sola al iniciar sesión. Lo puedes apagar en Ajustes → General.

> **¿Tiene que estar abierta?** Sí: es una app que corre en segundo plano (no aparece en el Dock). En reposo usa unos 20 MB de RAM y prácticamente 0 % de CPU.

---

## Conectar tus agentes

Todo se hace desde el menú ✨ (clic derecho):

| Agente | Cómo se conecta | Qué ves |
| --- | --- | --- |
| **Claude Code** | Menú ✨ → **Conectar Claude Code** | Estado, preguntas, planes y permisos desde el notch, resumen al terminar, contexto, tokens |
| **App de Claude** (escritorio) | **Automático** | Sesiones de Code y Cowork: trabajando, terminado, "te necesita" y límites de uso |
| **Cursor** | Menú ✨ → **Conectar Cursor** | Estado, archivos editados, comandos, resumen al terminar |
| **Codex** (CLI y app) | **Automático**, no hay que hacer nada | Estado, comandos, tokens, resumen al terminar, límites del plan |

> **Nota sobre la app de Claude:** VibeNotch lee los archivos que la propia app guarda en tu Mac, así que ve las sesiones de **Code** y **Cowork**. Los chats normales no dejan esa información en disco, por eso no aparecen. Se puede apagar en Ajustes → Agentes.

**¿Ya lo tenías conectado de una versión anterior?** Al actualizar, VibeNotch agrega sola los hooks nuevos (preguntas y planes). Solo reinicia tus sesiones de Claude Code.

**¿Qué hace "Conectar"?** Agrega unos *hooks* a `~/.claude/settings.json` o `~/.cursor/hooks.json` que avisan a VibeNotch de lo que pasa. Respeta tu configuración: la primera vez guarda una copia (`*.vibenotch-backup`), no toca tus otros hooks y, si el archivo tiene un error, no lo modifica. Para quitarlo, vuelve a hacer clic en la misma opción.

Si VibeNotch está cerrada, los hooks no hacen nada y tus agentes siguen funcionando normal: nunca bloquea a Claude ni a Cursor.

**Límites de Claude (opcional):** con Claude Code conectado ya ves los límites cuando usas Claude. Si quieres verlos siempre, activa **"Límites de Claude desde tu cuenta (Llavero)"**. Usa la sesión de Claude Code guardada en tu Llavero para preguntarle a Anthropic tu uso. macOS te pedirá permiso la primera vez.

---

## Con notch o sin notch, una o varias pantallas

VibeNotch **detecta sola** si la pantalla tiene notch y usa la versión que le toca. Si conectas un monitor o cambias de pantalla, se adapta al momento.

- **Mac con notch** (MacBook Pro 14"/16" 2021+, MacBook Air M2+): VibeNotch sale del notch como si fuera parte del Mac. Las pestañas se acomodan a los lados de la cámara para que nada quede tapado.
- **Mac sin notch, iMac o monitor externo**: aparece como una **isla** flotante debajo de la barra de menús. En reposo queda una pequeña asa arriba al centro para que sepas dónde está; se muestra completa cuando un agente trabaja, suena música o corre el temporizador. Al arrastrar un archivo aparece la zona **"Suéltalo aquí"**.
- **¿Prefieres otra?** En Ajustes → General → **Estilo** eliges Automático, Notch (dibuja un notch aunque tu pantalla no tenga) o Isla flotante.
- **Varias pantallas**: por defecto aparece **en la pantalla donde está tu mouse**. Lo puedes fijar en menú ✨ → **Mostrar en** → "Pantalla principal" o una pantalla específica.
- **Pantalla completa**: se esconde cuando ves un video o una app en pantalla completa.

<p align="center">
  <img src="docs/screenshots/isla-3-agentes.png" width="49%" alt="Modo isla (Mac sin notch)">
  <img src="docs/screenshots/notch-7-hoy.png" width="49%" alt="Modo notch">
</p>

---

## Personalizar

Abre **Ajustes** con el engrane ⚙️ del notch o con clic derecho en ✨ → **Ajustes…**

| Sección | Qué puedes cambiar |
| --- | --- |
| General | Estilo (automático, notch o isla), en qué pantalla aparece, qué tan rápido se abre al pasar el mouse, el asa de la isla, la zona para soltar archivos, abrir al iniciar sesión, sonidos y "menos animaciones" |
| Pestañas | Qué pestañas ves y en qué orden (por ejemplo, solo Agentes y Clips) |
| Hoy | Qué widgets aparecen y en qué orden |
| Agentes | Conectar o desconectar Claude Code y Cursor, seguir la app de Claude, responder preguntas desde el notch, mostrar resúmenes, cuándo quitar de la lista lo que ya terminó, límites desde el Llavero |
| Portapapeles | Pausar el historial, cuántos clips guardar (50 a 500), pegar al elegir, mostrar la canción en el notch cerrado |

---

## Consumo: RAM y batería

VibeNotch está hecha para quedarse abierta todo el día sin que lo notes. Medido en una MacBook Air M1 con 8 GB:

| En reposo | |
| --- | --- |
| RAM | ~20 MB |
| CPU | ~0.1 % |
| Despertares | ~2 por segundo |

Cómo lo logra:

- Las animaciones que se repiten (el spinner de "trabajando", el pulso y el ecualizador) las anima macOS directamente, sin redibujar la app.
- Detecta la pantalla completa con avisos del sistema en vez de revisar a cada rato.
- La batería avisa al instante cuando conectas el cargador, sin sondear seguido.
- El widget de Sistema solo mide mientras está a la vista.
- Buscar arma su índice solo cuando abres la pestaña (un par de segundos) y lo refresca, como mucho, cada 10 minutos.
- La app de Claude se revisa cada 3 s solo mientras está abierta, y cada 90 s si no.
- Con **Menos animaciones** (o la opción de accesibilidad de macOS) las animaciones decorativas se detienen.

---

## Atajos de teclado

| Atajo | Acción |
| --- | --- |
| **⌃⌥N** | Abrir / cerrar VibeNotch |
| **⌃⌥V** | Abrir el portapapeles |
| **⌃⌥F** | Buscar archivos |
| **↩ / ⌘↩** | En Buscar: abrir el archivo / mostrarlo en Finder |
| **⌃⌥1 … ⌃⌥9** | Copiar el texto guardado 1…9 |
| **⌘↩** | Guardar la nota que estás escribiendo |
| **⌘,** | Ajustes (con el menú ✨ abierto) |
| Clic en ✨ | Abrir / cerrar |
| Clic derecho en ✨ | Menú y ajustes |

(⌃ = Control, ⌥ = Option)

---

## Permisos

VibeNotch solo pide permisos cuando usas algo que los necesita:

| Permiso | Para qué | Cuándo lo pide |
| --- | --- | --- |
| Calendario | Mostrar tus próximos eventos y avisarte antes | Al tocar "Conectar calendario" en Hoy |
| Automatización (Spotify / Música) | Pausar y cambiar de canción | Al tocar un control de música |
| Accesibilidad | Pegar automáticamente al elegir un clip | Solo si activas "Pegar al elegir un clip" |
| Llavero | Leer los límites de tu plan de Claude | Solo si activas esa opción |
| Archivos (Escritorio, Documentos, Descargas, iCloud Drive) | Buscar archivos por nombre | La primera vez que abres Buscar |

Ver qué canción suena no necesita ningún permiso.

---

## Privacidad

- **Todo es local.** No hay cuentas, servidores, analíticas ni telemetría.
- Los agentes hablan con VibeNotch por un servidor que solo escucha en tu Mac (`127.0.0.1`) y está protegido con un token aleatorio.
- La única conexión a internet es opcional: la consulta de límites de Claude a Anthropic, con tu propia sesión, si activas esa opción.
- De la app de Claude solo lee, en tu Mac, el estado de las sesiones y los porcentajes de uso. Nunca lee tus conversaciones ni envía nada.
- Tus datos están en `~/Library/Application Support/VibeNotch` (historial, guardados, notas, estante).
- El índice de Buscar solo guarda nombres y fechas de archivos, vive en memoria y nunca se escribe en disco ni sale de tu Mac. No lee el contenido de tus archivos.

---

## Solución de problemas

<details>
<summary><b>No veo nada en el notch / en la pantalla</b></summary>

- Revisa que haya un ✨ en la barra de menús. Si no, abre VibeNotch desde Aplicaciones.
- En Macs sin notch la isla se esconde cuando no pasa nada: pasa el mouse **arriba al centro** o presiona **⌃⌥N**.
- Con varias pantallas, aparece donde está el mouse. Cámbialo en menú ✨ → **Mostrar en**.
- Si tienes muchos íconos en la barra de menús (Bartender, Ice…), el ✨ puede estar escondido; el atajo ⌃⌥N siempre funciona.
</details>

<details>
<summary><b>"VibeNotch está dañada y no se puede abrir"</b></summary>

Es el bloqueo de Gatekeeper para apps descargadas fuera de la App Store. Corre:

```bash
xattr -dr com.apple.quarantine /Applications/VibeNotch.app && open /Applications/VibeNotch.app
```
</details>

<details>
<summary><b>Claude Code o Cursor no aparecen</b></summary>

- Menú ✨ → debe decir **"Claude Code conectado"** / **"Cursor conectado"**.
- Reinicia la sesión del agente (los hooks se leen al iniciar).
- En Claude Code, `/hooks` muestra si los hooks de VibeNotch están activos.
- Codex aparece en cuanto empieza una sesión nueva (lee `~/.codex/sessions`).
- La app de Claude aparece cuando usas Code o Cowork dentro de ella (Ajustes → Agentes → "App de Claude" encendido).
</details>

<details>
<summary><b>Las preguntas de Claude no salen en el notch</b></summary>

- Revisa Ajustes → Agentes → "Responder preguntas y aprobar planes desde el notch".
- Reinicia la sesión de Claude Code después de actualizar VibeNotch (los hooks nuevos se leen al iniciar).
- Si no respondes en unos 5 minutos, la pregunta regresa a la terminal: nunca se queda trabada.
</details>

<details>
<summary><b>"Comprimir" no achicó mi archivo</b></summary>

Si ves **"Ya estaba optimizado"**, tu archivo ya viene comprimido (por ejemplo un JPG de WhatsApp o un MP4 de redes) y hacerlo más chico lo haría verse peor. Para mandar muchos archivos juntos usa **Hacer .zip**: un zip junta archivos pero casi no reduce fotos ni videos, que ya vienen comprimidos.
</details>

<details>
<summary><b>Los atajos no funcionan</b></summary>

Otra app puede estar usando la misma combinación (⌃⌥N / ⌃⌥V). Ciérrala o cambia su atajo.
</details>

<details>
<summary><b>"Pegar al elegir un clip" no pega</b></summary>

Ve a **Ajustes del Sistema → Privacidad y seguridad → Accesibilidad** y activa VibeNotch. Si ya estaba, quítala con "–" y vuelve a agregarla (pasa después de actualizar).
</details>

---

## Desinstalar

Un comando que quita la app, **solo** los hooks de VibeNotch (el resto de tu configuración de Claude/Cursor queda igual, y guarda copia) y sus datos:

```bash
curl -fsSL https://raw.githubusercontent.com/uriel123-coder/vibenotch/main/scripts/uninstall.sh | bash
```

O a mano: menú ✨ → desconecta Claude Code y Cursor → Salir, y borra `/Applications/VibeNotch.app`, `~/.vibenotch` y `~/Library/Application Support/VibeNotch`.

---

## Compilar desde el código

Solo necesitas las **Command Line Tools** (`xcode-select --install`); no hace falta Xcode ni SwiftPM.

```bash
./build.sh            # app universal (Apple Silicon + Intel) en build/
./build.sh debug      # compilación rápida para tu Mac
./build.sh install    # compila, copia a /Applications y abre
./build.sh zip        # compila y crea build/VibeNotch.zip para compartir
```

### Estructura

```
Sources/VibeNotch/
├── App/          arranque, menú, atajos globales, modo de capturas
├── Notch/        ventana, detección de notch / isla, varias pantallas, estado
├── Agents/       Claude Code y Cursor (hooks + servidor local), Codex y app de Claude (leen sesiones)
├── Shelf/        estante de archivos
├── Search/       índice en memoria y búsqueda de archivos por nombre
├── Clipboard/    historial, guardados y notas
├── Tools/        conversión y compresión (ImageIO, Vision, PDFKit, AVFoundation)
├── Extras/       música, calendario, batería, temporizador, sistema
└── Views/        SwiftUI (notch, pestañas y ventana de ajustes)
```

### Capturas y pruebas

```bash
VIBENOTCH_SNAPSHOT=/tmp/shots ./build/VibeNotch.app/Contents/MacOS/VibeNotch                       # modo isla
VIBENOTCH_SNAPSHOT=/tmp/shots VIBENOTCH_FAKE_NOTCH=1 ./build/VibeNotch.app/Contents/MacOS/VibeNotch  # simula notch
VIBENOTCH_SNAPSHOT=/tmp/shots VIBENOTCH_SELFTEST=1 ./build/VibeNotch.app/Contents/MacOS/VibeNotch    # + prueba los conversores
VIBENOTCH_SEARCHTEST=factura ./build/VibeNotch.app/Contents/MacOS/VibeNotch                        # mide el índice y la búsqueda
```

Genera todas las pantallas con datos de ejemplo, sin tocar tus datos reales ni la copia de VibeNotch que tengas abierta.

### Publicar una versión

Sube `CFBundleShortVersionString` en `Resources/Info.plist` y crea un tag: GitHub Actions compila la app universal y la publica en Releases.

```bash
git tag v1.2.1 && git push origin v1.2.1
```

¿Ideas o errores? Abre un [issue](https://github.com/uriel123-coder/vibenotch/issues). Los PRs son bienvenidos.

---

## English

**VibeNotch** turns your Mac's notch into a control center. On Macs without a notch it shows up as a floating island. It has six tabs:

- **Agents:** live status for Claude Code, the Claude desktop app (Code and Cowork sessions), Codex and Cursor. Answer Claude's multiple-choice questions, approve plans and allow or deny permissions right from the notch. When a task ends you see a checkmark, a summary of the reply and how long it took. You also get context/token usage and your 5-hour and weekly plan limits. Cursor sessions show up as Cursor even though Cursor runs Claude Code's hooks, and finished sessions clear themselves after 10 minutes (configurable).
- **Shelf:** a Dropover-style shelf. Drop files on the notch and drag them out later; you can also shrink them, zip them, AirDrop them or copy their paths. Without a notch, a "Drop here" zone appears as soon as you start dragging.
- **Search (⌃⌥F):** find any file by name in milliseconds, or see your recent files. Filter by documents, PDFs, images, videos or folders; press ↩ to open, ⌘↩ to reveal in Finder, or drag the result anywhere. It builds its own in-memory index of your folders, so it works even with Spotlight turned off.
- **Clips:** searchable history, saved snippets on **⌃⌥1-9**, and sticky **notes** you copy with one click. Passwords are ignored.
- **Today:** widgets you pick and order: music, timer, pinned notes, battery, calendar and a system monitor (CPU, RAM, disk).
- **Convert:** 23 local tools. Image formats, real compression (it tries several encodings and keeps the smallest good one, or tells you the file was already optimized), background removal, OCR, merging PDFs, video to MP4/GIF, audio extraction, zip/unzip.

It detects whether your screen has a notch and switches between notch and island automatically (you can force either in Settings). Idle it uses about 20 MB of RAM and ~0.1% CPU.

**Install** (macOS 14+, Apple Silicon or Intel):

```bash
curl -fsSL https://raw.githubusercontent.com/uriel123-coder/vibenotch/main/scripts/install.sh | bash
```

Or download the zip from [Releases](https://github.com/uriel123-coder/vibenotch/releases/latest). The app is ad-hoc signed, so the first time right-click → Open, or run `xattr -dr com.apple.quarantine /Applications/VibeNotch.app`.

Open it with **⌃⌥N**, by hovering the top center of the screen, or by clicking ✨ in the menu bar. The gear inside the notch opens Settings (tabs, widgets, style, hover speed…). Right-click ✨ to connect Claude Code or Cursor. Codex and the Claude app are picked up automatically. Everything runs locally, with no accounts and no telemetry.

MIT © 2026 Uriel Nakach
