# XR Demo Suite — Novembre 2026

Prototipo Godot/OpenXR per Meta Quest: catalogo industriale e arredi, dati
Open Data Hub e assistente voce/visione tramite il server del progetto.
La base di ottobre è congelata; questo worktree sviluppa novembre.

## Da dove partire

| Serve… | Riferimento |
| --- | --- |
| Avviare, configurare o esportare | Questo README |
| Capire componenti e modificare scene/interazioni | [Architettura](docs/architecture.md) |
| Mettere due Quest nella stessa stanza | [Esperienza condivisa](docs/condivisione.md) |
| Prodotti, fonti, Blender, texture e QR | [Asset e catalogo](docs/assets.md) |
| Controlli, prova nel Quest e problemi noti | Collaudo (guida interna) |
| Versioni, archivio di ottobre e ripristino | Release (guida interna) |

Questi sono i riferimenti della suite. Le vecchie guide sovrapposte
restano nella cronologia Git. Configurazione e protocollo del proxy hanno il
proprio [README nel server](../xr-demo-server/README.md).

## Ambiente e avvio

Ambiente usato per le verifiche: **Godot 4.7 stable**, renderer Mobile;
Android SDK/JDK e template di esportazione della stessa versione di Godot.
Blender serve solo per preparare gli asset, non per eseguire la demo.

Aprire `project.godot` di questa directory, branch principale Le sperimentazioni nella directory originale sono indipendenti.

Dalla directory `xr-demo-suite`, prima importazione e controllo degli script:

```sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --xr-mode off --editor --path . --import --quit
```

`scenes/app/Main.tscn` è l'ingresso dell'app. L'avvio normale richiede OpenXR:
un errore XR su desktop senza runtime/visore non equivale a un errore di importazione.
Per render desktop usare gli script indicati nel collaudo (guida interna).

## Configurazione della demo

| Funzione | Dove intervenire |
| --- | --- |
| Catalogo locale, fonti e dimensioni | `data/industrial_models.json` |
| Stanze e associazioni Open Data Hub | `data/noi_rooms.json`, `scenes/services/OpenDataHubClient.tscn` |
| Connessione all'assistente | `ws_url` in `scenes/services/XRAgentClient.tscn` |
| Layout, testi, materiali e parametri XR | Scene e risorse elencate in [architettura](docs/architecture.md) |
| Provider, STT, LLM, TTS e credenziali | `xr-demo-server/.env`, secondo il README del server |

L'URL del proxy salvato nella scena è `ws://192.168.1.100:8091/ws/realtime`:
adattarlo alla rete usata e riesportare se cambia. Il Quest non contiene le
credenziali dei provider. Il catalogo funziona senza il server; Open Data Hub
e assistente richiedono connettività. Il Digital Twin carica il campus Blender alleggerito, poi materiali e singoli
piani su richiesta. I sensori di Bolzano mostrano solo misure sotto i 5 minuti;
fonti, associazioni e limiti sono in [architettura](docs/architecture.md).

## Esportazione Android

Nell'editor configurare i percorsi Android SDK/JDK e installare il template
Android della versione corrente. Conservare le librerie in `android/build/libs`:
sono componenti del motore, non vecchi APK eliminabili.

```sh
mkdir -p build
/Applications/Godot.app/Contents/MacOS/Godot --headless --xr-mode off --path . --export-debug Android build/xr-demo-november-dev21.apk
```

Il preset è ARM64, package `com.example.xrnoi`, nome
**NOI XR · Novembre**. Versione e codice sono in `export_presets.cfg`.
Usare collaudo e installazione (guida interna) prima di considerare pronta
una build. L'app di ottobre ha un package distinto.

## Cosa tenere in Git

Scene, script, cataloghi, asset runtime, sorgenti Blender necessari, fonti e
licenze. Le texture esterne accanto ai GLB sono necessarie: copiarle insieme.
Cache `.godot/`, `android/build/`, APK e render in `build/` sono locali e ignorati.
I `.uid` e i file `.import` delle risorse restano versionati.
