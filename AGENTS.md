# VibeNotch: reglas para agentes (Codex, Claude, Cursor)

## El asistente (Jarvis) necesita compilar en CI

- Todo el código del modelo de Apple (`FoundationModels`) está dentro de `#if canImport(FoundationModels)` y `@available(macOS 26, *)`.
- El SDK de esta Mac **no tiene FoundationModels**: `./build.sh` local compila, pero el binario sale **sin cerebro** (el asistente no platica ni entiende).
- Por eso: **nunca instales en `/Applications` una compilación local**. Solo se instala el zip del release de GitHub, que compila CI (macos-26).
- Que compile en local no prueba nada de esa parte. Después de cada push revisa CI: `gh run watch <id> -R uriel123-coder/vibenotch --exit-status`. Si CI falla, la versión está rota.
- Verifica que el binario instalado tenga el modelo: `otool -L /Applications/VibeNotch.app/Contents/MacOS/VibeNotch | grep -c FoundationModels` debe ser mayor que 0.
- `Tool` choca con un tipo de la app; si usas herramientas del modelo, escribe `FoundationModels.Tool`.

## Límites del modelo local

- Modelo de unos 3B parámetros con unos 4096 tokens de contexto: instrucciones largas, herramientas o textos grandes lo hacen fallar sin respuesta.
- Los textos largos se procesan por pedazos (`Brain.process`, unos 2600 caracteres).
- Las órdenes comunes se resuelven con reglas instantáneas (`Rules`, `Quick`); el modelo solo decide lo que las reglas no entienden.

## Probar

- Reglas, sin hacer nada real: `VIBENOTCH_AGENTTEST='orden|otra' build/VibeNotch.app/Contents/MacOS/VibeNotch`.
- Con el modelo: descarga el artefacto de CI (`gh run download <id> -R uriel123-coder/vibenotch -n VibeNotch`) y corre lo mismo con esa app.
- No mandes mensajes reales por WhatsApp para probar. Los datos de WhatsApp solo se leen, nunca se escriben.
- Al abrir la app no leas datos de otras apps (WhatsApp, Mail): macOS pide «acceder a datos de otras apps» en cada actualización. Léelos solo cuando una orden los necesite.
- Ventanas propias (paneles, overlays) llevan `hidesOnDeactivate = false`: VibeNotch casi nunca es la app de enfrente.

## Publicar

1. Sube la versión en `Resources/Info.plist` (`CFBundleShortVersionString` y `CFBundleVersion`).
2. Commit, push y espera CI en verde.
3. `git tag vX.Y.Z && git push origin vX.Y.Z`, espera el release y descarga su zip.
4. Instala ese zip y verifica la firma: `codesign -dr - /Applications/VibeNotch.app` debe mostrar `certificate root = H"ce8866669c26ec85ea29b117e4523643c5191b7f"`.
