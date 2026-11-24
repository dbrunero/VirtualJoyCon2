# 3. Movimento: assi, calibrazioni, profili Sport/Golf

Il movimento è la parte delicata: il gioco ricostruisce l'orientamento del Joy-Con integrando il giroscopio e usando la gravità dell'accelerometro. Se uno dei due arriva sbagliato, la mazza deriva, carica da sola o va al contrario.

## Ordine consigliato (una volta sola)

1. **Misura assi…** — obbligatoria la prima volta.
2. *(facoltativo)* **Calibra sensibilità** — *Misura assi* la misura già, serve solo se cambi tipo di MotionPlus.

Entrambe restano salvate (vedi [Cosa viene salvato](05-impostazioni-salvate.md)).

## Misura assi (procedura guidata)

**Perché serve.** Il lettore del Wii Remote converte i suoi assi in quelli standard con segni scelti a mano. Se un segno è sbagliato, il movimento arriva **specchiato**: l'inclinazione sembra giusta, ma destra e sinistra sono scambiate. Per un gioco questo vuol dire, per esempio, che un mancino viene visto come destro. Uno specchio **non si corregge con nessuna rotazione**, quindi le "Correzioni assi" non bastano: bisogna misurare.

**Come si fa.** Nella finestra del giocatore premi *Misura assi…*. Durante la procedura i tasti non arrivano al gioco.

1. Telecomando **disteso**, punta verso lo schermo, **tasti in su**. Fermo, premi **A**.
2. **Punta verso il soffitto** (tasti verso di te). Fermo, premi **A**.
3. Disteso verso lo schermo, poi giralo sul fianco: **fianco destro in alto** (tasti verso sinistra). Fermo, premi **A**.
4. Per **20 secondi**: rotazioni lente e ampie in tutte le direzioni (punta su e giù, di lato, girato), con **pause da fermo** di un secondo.

Se una posa non era ferma compare "Si muoveva": tienilo immobile e premi di nuovo A.

**Cosa calcola.**
- Le tre pose fissano il segno di ogni asse dell'accelerometro rispetto agli assi veri (+X destra, +Y fuori dalla faccia dei tasti, +Z verso di te), specchio compreso.
- Le rotazioni servono per il giroscopio: l'app prova tutte le **48 combinazioni** di assi e segni e tiene quella per cui la gravità ruota esattamente come dice il giroscopio. Misura anche la **sensibilità**.
- Il risultato vale per **tutti i telecomandi** e riporta le correzioni assi su Standard.

**Controllo finale.** La finestra mostra cosa vede l'app:

| Fai così | Deve comparire |
|---|---|
| Punta al soffitto | Punta in su |
| Fianco destro in alto | fianco destro in su |
| Gira il telecomando verso sinistra (come per indicare a sinistra) | gira a SINISTRA |

Se corrisponde, il gioco riceve il movimento vero e le impostazioni "mancino/destro" del gioco funzionano.

## Zero del giroscopio (calibrazione automatica)

Il MotionPlus a telecomando fermo non legge esattamente zero: va misurato lo **zero**.

- Alla connessione l'app usa lo **zero salvato la volta scorsa** per quel telecomando: si gioca subito.
- Appena il telecomando sta fermo un secondo (in qualsiasi posizione) lo rimisura e lo salva.
- Mentre è appoggiato su un piano corregge piano piano la deriva termica, e salva anche questa.
- **Ricalibra giroscopio**: rimisura forzata, appoggiato a faccia in giù su un piano.

## Sensibilità

Fattore di scala del giroscopio (tipicamente 0,93–0,97). È uno per tipo di MotionPlus (integrato o adattatore esterno) e vale per tutti i giocatori. *Misura assi* la imposta; *Calibra sensibilità* la rimisura da sola (20 secondi di movimenti ampi con pause).

## Profili Sport e Golf

Ogni giocatore ha due profili e si passa dall'uno all'altro con **Home+1** (tenuti ~0,6 s) o dalla finestra del giocatore.

| | Sport (tennis, ping pong, bowling…) | Golf |
|---|---|---|
| Correzione assi | la sua (Standard dopo *Misura assi*) | la sua (Standard dopo *Misura assi*) |
| Giroscopio da fermo | passa tutto | sotto 2°/s vale **zero**: la deriva non carica il tiro all'indirizzo |
| Correzione dell'inclinazione | rapida (fino a 60°/s dopo 80 ms da fermo) | lenta (fino a 6°/s dopo 300 ms da fermo): il gioco non la scambia per un backswing |
| Consegna dello swing | 60% dell'angolo per pacchetto (più liscio) | 90% (picco di velocità più fedele, cioè potenza più costante) |

## Correzione dell'inclinazione (in entrambi i profili)

Il Bluetooth perde campioni negli swing veloci, e ogni campione perso è un errore che il gioco accumula: dopo qualche colpo la punta non è più dove dovrebbe. A telecomando fermo l'app confronta la gravità "vista" dal gioco con quella vera e ruota piano la prima verso la seconda. Corregge inclinazione e rollio. La **direzione orizzontale** invece non ha un riferimento (senza Sensor Bar né bussola): la rimette a posto il ricentramento del gioco.

## Posizione al tasto

Facoltativa. Scegli un tasto e un angolo (45° o perpendicolare): quando premi quel tasto il gioco vede la punta esattamente a quell'angolo rispetto alla verticale, finché non lo premi di nuovo. Serve nei giochi che chiedono una posa precisa prima del colpo.
