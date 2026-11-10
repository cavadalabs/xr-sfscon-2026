# Esperienza condivisa — guida rapida

Due o più Quest nella stessa stanza fisica, stesso arredamento condiviso.
Serve la demo **Industria**; il progetto voce e i dati aperti restano locali.

## Prerequisiti

- Tutti i Quest sulla **stessa Wi-Fi** (la stanza è raggiungibile in LAN;
  l'IP manuale, se serve, è quello del Quest host).
- Stesso APK su tutti i visori (stessa build: un APK misto non si accorda
  sul protocollo).
- Scansione della stanza completata su ogni Quest: senza scansione la
  condivisione funziona ma l'ancoraggio comune no (vedi **Allineamento**).

## Aprire la lobby

Nel pannello catalogo: **Esperienza Condivisa**. La lobby offre due strade:

- **Crea stanza** (host): il Quest apre la stanza e mostra il **codice di
  4 cifre**. L'host è l'autorità: valida ogni mossa e tiene il mondo.
- **Entra** (client): lista degli host trovati in LAN (*In ricerca…*),
  **Entra col codice** con le 4 cifre mostrate dall'host, o **IP manuale**
  come ultimo resort.

Il nome della stanza è personalizzabile (**Cambia nome**, solo host): le
modifiche arrivano a tutti con la stessa ricerca LAN.

## In stanza

Una volta dentro il mondo condiviso è **uno solo**: gli arredi piazzati,
spostati, animati ed eliminati compaiono identici su tutti i visori.
Restano personali il catalogo, l'anteprima del prodotto e la posizione dei
pannelli.

Chi afferra un arredo lo **blocca**: gli altri lo vedono muoversi in tempo
reale ma non possono toccarlo finché il possesso dura. Il rilascio
conferma la posa per tutti.

### Permessi

Ognuno sceglie la propria modalità dal pulsante **Privata/Condivisa**
della vista stanza:

- **Privata** — *Solo io muovo i miei arredi* (default).
- **Condivisa** — *I miei arredi sono muovibili da tutti*.

L'host può sempre muovere tutto.

## Allineamento

Il mondo condiviso **appare solo dopo il primo riconoscimento dello
spazio**: è il punto per cui due visori vedono lo stesso tavolo, non due
stanze sovrapposte. Da lì in poi il mondo resta visibile anche se il
runtime perde l'ancora (standby): l'ultima posa vale e il mondo torna
al suo posto quando l'ancora è ritrovata.

Se l'ancoraggio si rompe in modo irreversibile la lobby mostra
**Riconosci di nuovo lo spazio / Riprova**: il pulsante c'è solo quando
serve davvero.

## Cadere e tornare

La riconnessione è automatica con backoff: se il client riprende la
connessione, il mondo viene ri-sincronizzato da solo. Se l'host chiude,
il client resta in lobby con **Riprova** finché l'host riapre la stessa
stanza.

## Uscire

- **Esci dalla stanza**: ti disconnetti, il mondo resta agli altri.
- **Reset stanza** (solo host): rimuove tutti gli arredi, la stanza
  riapre vuota.

## Se qualcosa non si vede

Tabella completa nel collaudo (guida interna). In breve:

| Sintomo | Controllo |
| --- | --- |
| L'altro non entra | stesso Wi-Fi, host in lobby, codice giusto; IP manuale come prova |
| Arredo non arriva | `XR_DIAG` nel log Quest: `net-reject` = l'host rifiuta, `net-in` senza `net-ack` = applicazione mancata |
| Due stanze sovrapposte | allineamento mancato: scansione fatta, **Riprova** |
| Movimento fantasma | l'arredo è in presa a un altro: etichetta *IN PRESA · nome* col colore del possessore |
