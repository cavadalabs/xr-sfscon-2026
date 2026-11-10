# Guida all'editor — cosa si cambia da Godot, senza toccare codice

Regola generale: **la scena (`.tscn`) decide l'aspetto, lo script decide il
comportamento.** Per cambiare look, posizioni, testi, colori e dimensioni si
lavora solo nell'editor: si apre la scena, si seleziona il nodo, si modifica
l'ispettore, si salva. Poi si riesporta l'APK e si prova nel visore.

Le proprietà con il commento in italiano appaiono nell'ispettore come gruppo
(es. "Colori", "Beacon e marker") con il loro nome e un passaggio a capo che
spiega cosa fanno.

## Pannelli e bottoni

| Scena | Cosa si cambia |
|---|---|
| `scenes/ui/MainMenu3D.tscn` | Menu principale: card delle demo, titoli, posizioni |
| `scenes/ui/DemoButton3D.tscn` | Il bottone base (forma, colori, etichette). **Attenzione:** è il modello di tutti i bottoni del progetto: qui si cambia solo il design generale |
| `scenes/demos/industrial/IndustrialCatalogPanel.tscn` | Pannello catalogo industriale: griglia bottoni di controllo (Shared, Elimina, Scala+, ecc.) — posizioni, titoli, colori |
| `scenes/demos/industrial/SharedLobbyPanel.tscn` | Pannello lobby condivisione: codici, stati, bottoni |
| `scripts/ui/info_panel_3d.gd` | Pannello informazioni (quello trascinabile): testo, dimensioni. Composto inline nelle scene demo, non ha un .tscn dedicato |
| `scenes/ui/WristMenuModelSlot3D.tscn` | Menu al polso: i slot con la miniatura del prodotto (il contenitore e' `IndustrialCatalogPanel.tscn`). Nell'ispettore dello slot: colori, luminosita' da selezionato, riempimento miniatura |

## Componenti riutilizzabili

| Scena | Cosa si cambia |
|---|---|
| `scenes/ui/XRPanelDragHandle3D.tscn` | La maniglia per trascinare i pannelli: dimensioni, colore, a che distanza appare. Ispettore: `handle_size`, `handle_color`, `view_offset` |
| `scenes/xr/XRRoomPlacementBody3D.tscn` | Il "volume stanza" che evita i muri: raggio di sicurezza (`wall_clearance`, `min_clearance`) |
| `scenes/demos/industrial/IndustrialHotspot.tscn` | I marker numerati sul macchinario: la sfera e il testo stanno qui; raggio sensibile e colore hover nell'ispettore (`hit_radius`, `hover_color`) |
| `scenes/demos/industrial/FurnitureItem.tscn` | Un arredo posizionato: etichetta "SELEZIONATO" (testo, font) e distanza dell'etichetta dal modello (`selection_label_gap`) |
| `scenes/xr/RemoteHandCursor.tscn` | Il cursore delle mani degli altri partecipanti: forma e dimensione. Il **colore** è il colore utente, dalla palette (sotto) |
| `scenes/demos/opendata/DataBeacon.tscn` | Il beacon verde/grigio sulla mappa OpenData: la sfera e il testo stanno qui |
| `scenes/demos/llm/NoiBotController.tscn` | NoiBot, l'assistente: modello e animazioni. Ispettore: intensità movimenti (`motion_intensity`) |

## Mappa OpenData (`scenes/demos/opendata/NoiMap.tscn`)

La scena contiene: base, titoli, i **5 bottoni fissi** (Campus, Apri, Colori,
Piano −, Piano +) e `SelectionRoot`.

- **Bottoni fissi**: sono nodi veri sotto `Controls` — si spostano, si
  ridimensionano, si cambiano i titoli direttamente nella scena.
- **Ispettore dello script** (selezionare il nodo `NoiMap`):
  - *Comportamento*: larghezza mappa, sollevamento modello, velocità etichette,
    zoom minimo/massimo
  - *Colori*: beacon "vivo", neutro, campus fantasma, piani, stanza
    selezionata, area di selezione
  - *Beacon e marker*: quanto sporge il beacon, raggio, dimensione dei marker
    "1 · Lab", distanze, etichette edificio
  - *Bottoni stanza*: posizione del primo, distanza fra due, dimensione
    (i bottoni stanza sono uno per stanza e li crea il codice dall'API, ma
    stanno a griglia: la griglia si regola da qui)

## Demo industriale (colori e regole)

- **Palette colori partecipanti**: `user_colors` nell'ispettore del nodo
  `AppServices/SharedState` in `Main.tscn` (persistente tra le demo). L'ordine è
  l'assegnazione ai peer.
- **Numero massimo di arredi**: `max_furniture` nell'ispettore del nodo
  `TechnicalNodes/IndustrialModelPlacementController` (in `IndustrialDemo.tscn`).

## Cosa resta nel codice (e perché)

- **Numeri di fisica/rituali interni** (epsilon, soglie di collisione, tempi
  di smoothing): non sono cose da design, metterli nell'editor porterebbe solo
  rotture.
- **Tutto ciò che arriva dall'API o dai file JSON** (stanze, misure, catalogo
  arredi, descrittori edificio): sono dati, stanno in `data/*.json` e negli
  asset, non nella scena.
- **Mesh generate a runtime** (riempimento/contorno dell'area selezionata,
  anteprime di posizionamento): la forma dipende dai dati, quindi nasce dal
  codice — ma il **colore** è ora esportato.

## Flusso di lavoro consigliato

1. Aprire la scena in Godot, modificare, `Ctrl+S`.
2. `Progetto > Esporta` (o lo script di build) → APK → installare su entrambi
   i visori → **provare nel visore** (il test headless non copre la resa XR).
3. Se qualcosa sparisce o si sposta: controllare che il nodo non abbia
   `visible = false` o scala 0, e che le posizioni dei bottoni non si sovrappongano
   (la griglia del catalogo è 4 colonne × 3 righe).
