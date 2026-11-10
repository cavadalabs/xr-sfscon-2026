# AGENTS.md

## Missione

Costruire un template Godot/OpenXR piccolo e didattico per un hackathon sugli
Open Data. Il progetto deve essere comprensibile in circa 10 minuti: una scena
funzionante, dati locali semplici e pochi punti di modifica chiari.

Questa repository parte volutamente quasi vuota. Non trasformarla in un
framework.

## Requisiti non negoziabili

- Il passthrough deve essere attivo fin dall'avvio su un visore compatibile. Non
  è un bonus e non deve richiedere una scena alternativa o un toggle manuale.
- La stessa demo deve restare avviabile e modificabile anche da desktop, senza
  visore.
- La demo prova una sola chiamata REST pubblica a Open Data Hub all'avvio e usa
  un solo JSON locale esclusivamente come fallback per errori o assenza di rete.
- Preferire scene e Inspector per nodi, proprietà statiche e signal connection.
  Usare GDScript solo per comportamento realmente dinamico.
- Nessuna architettura speculativa: niente base class, normalizer, manager o
  dependency aggiuntive finché un caso concreto non le rende necessarie.

## MVP atteso

Una sola dashboard spaziale deve:

1. caricare 5-10 elementi da un endpoint Open Data Hub pubblico;
2. creare una card per ogni elemento;
3. mostrare nome, valore, unità e stato;
4. mostrare descrizione e dettagli quando si seleziona una card;
5. rappresentare valore o stato tramite colore e altezza;
6. ripiegare su un unico JSON locale se la richiesta fallisce;
7. partire in XR con passthrough già attivo quando OpenXR è disponibile.

Formato dati comune:

```json
{
  "name": "Passo Sella",
  "value": 33,
  "capacity": 199,
  "unit": "free spaces",
  "status": "limited",
  "description": "33 of 199 parking spaces are free."
}
```

Mantenere un solo esempio locale, con lo stesso formato usato dalle card live.

## Struttura obiettivo

Mantenerla vicina a questa, aggiungendo file solo se Godot/OpenXR li richiede
davvero:

```text
README.md
HACKATHON_BRIEF.md
DATA_IDEAS.md
godot/
  project.godot
  scenes/
    main.tscn
    data_card.tscn
  scripts/
    main.gd
    data_source.gd
    data_card.gd
  data/
    fallback_parking.json
  tests/
    verify_mvp.gd
```

Non creare ulteriori livelli (`services`, `models`, `managers`) prima che servano.

## Tre livelli per i partecipanti

- Base: disattivare `Use Live Data` nell'Inspector e modificare il JSON di fallback.
- Intermedio: cambiare colori, soglie o rappresentazione della card.
- Avanzato: cambiare endpoint e mapping dal nodo `DataSource` nell'Inspector.

Sono tre modi di estendere la stessa demo, non tre architetture diverse.

## Regole di lavoro per l'agente

- Prima di scrivere codice, leggere completamente i file coinvolti e cercare
  soluzioni già presenti nel repository.
- Il repository fratello `../xr-demo-suite` può essere consultato in sola
  lettura per riusare configurazione OpenXR e passthrough già collaudata. Non
  modificarlo mentre si lavora qui e non copiarne l'architettura completa.
- Usare API native di Godot (`FileAccess`, `JSON`, `HTTPRequest`) prima di
  introdurre plugin o utility.
- Fare cambi piccoli e verificabili. Conservare sempre le modifiche
  preesistenti dell'utente.
- Non committare file generati, cache, build, credenziali o endpoint privati.
- Non dichiarare il passthrough verificato su hardware se è stato controllato
  soltanto dall'editor o in modalità headless.
- Se un dettaglio non è deciso, scegliere il comportamento più semplice e
  segnalarlo chiaramente invece di costruire flessibilita preventiva.

## Verifica minima

Prima di considerare completo l'MVP:

- import e parsing del progetto Godot senza errori;
- avvio desktop e interazione con almeno una card;
- risposta live valida oppure caricamento del JSON di fallback;
- assenza di errori quando OpenXR non è disponibile;
- prova reale su visore compatibile: sessione XR avviata e passthrough visibile
  immediatamente.

## README

Mantenere il README pratico, verificabile e adatto a chi non ha mai usato Godot
o Meta Quest. Evitare testo promozionale generico. Deve almeno contenere:

- obiettivo della sfida in linguaggio rassicurante;
- avvio in cinque passi;
- percorso desktop e percorso visore;
- i tre livelli di partecipazione;
- formato dati con un esempio;
- come cambiare endpoint e mapping Open Data Hub dal nodo `DataSource`;
- requisiti, troubleshooting essenziale e limiti realmente verificati.

La frase guida del progetto è:

> Non dovete costruire un'app XR da zero: dovete mostrare come un dato reale
> può diventare più comprensibile quando viene visualizzato nello spazio.
