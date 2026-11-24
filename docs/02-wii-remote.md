# 2. Wii Remote

Serve un **Wii Remote Plus** (MotionPlus integrato) o un Wii Remote con l'adattatore **MotionPlus** esterno. Senza MotionPlus funzionano tasti e accelerometro, ma non il giroscopio: i giochi di movimento non vanno bene.

## Accoppiamento e connessione

- **Prima volta per ogni telecomando**: *Accoppia nuovo Wii Remote*, poi il tasto rosso **SYNC** sotto il coperchio delle pile. Il registro dell'ultimo tentativo finisce in `wiimote_pair.log`.
- **Le volte dopo**: basta premere **1+2** (o un tasto qualsiasi) sul telecomando.
- Fino a **4 telecomandi**: ognuno prende il primo posto libero e accende il LED del suo numero.
- Ogni giocatore ha il **proprio controller virtuale**, che compare quando il telecomando si collega e sparisce quando si scollega.

## Finestra del giocatore

Clicca su un giocatore per aprire le sue impostazioni.

| Impostazione | Cosa fa |
|---|---|
| Interruttore | Attiva o mette in pausa il giocatore |
| **Uscita** | *Joy-Con classico* (Joy-Con (L)/(R) Switch 1, protocollo Nintendo completo) oppure *Joy-Con 2* (gamepad virtuale Joy-Con 2) |
| **Lato** | Joy-Con sinistro o destro. Di default i giocatori dispari sono sinistri, i pari destri |
| **Impugnatura** | *Verticale* (come un telecomando, giochi di movimento) o *Orizzontale* (di traverso, stile NES) |
| Ricalibra giroscopio | Rimisura lo zero del MotionPlus: appoggialo a faccia in giù su un piano, fermo per un secondo |
| Calibra sensibilità | Misura di quanto il giroscopio sbaglia la velocità (vedi [Movimento](03-movimento.md)) |
| **Misura assi…** | Procedura guidata che rende il movimento non specchiato (vedi [Movimento](03-movimento.md)) |
| Posizione al tasto | Alla pressione del tasto scelto il gioco vede la punta a 45° o perpendicolare, a prescindere da come la tieni |
| **Profilo** | Sport o Golf (vedi [Movimento](03-movimento.md)) |
| Correzione assi Sport / Golf | Rotazioni correttive per profilo. Dopo *Misura assi* lasciale su **Standard** |
| Vibrazione | Il motore del Wii Remote vibra quando il gioco fa vibrare il Joy-Con |
| Mappa tasti… | Cambia a cosa corrisponde ogni tasto |

## Mappatura tasti predefinita (impugnatura verticale)

Il destro è lo specchio del sinistro per posizione: stesso tasto fisico, stessa posizione sul Joy-Con.

| Wii Remote | Joy-Con sinistro | Joy-Con destro |
|---|---|---|
| Croce | Stick | Stick |
| 1 (in alto) | ↑ | X |
| 2 (in basso) | ↓ | B |
| − (a sinistra) | ← | Y |
| + (a destra) | → | A |
| A | Clic stick L | Clic stick R |
| B (grilletto) | ZL | ZR |
| Home | − | + |
| Nunchuk C / Z | SL / SR | SL / SR |
| Stick Nunchuk | Stick (vince sulla croce) | Stick |

Con l'uscita **Joy-Con 2**, che non ha SL/SR, i tasti che andrebbero a SL/SR vanno a L/ZL (sinistro) o R/ZR (destro).

La mappatura è **condivisa** tra tutti i giocatori con la stessa combinazione di uscita, lato e impugnatura. *Ripristina* nella finestra di mappatura torna a quella predefinita.

## Combinazioni sul telecomando

| Combinazione | Effetto |
|---|---|
| **Home+1** tenuti premuti ~0,6 s | Cambia profilo: 1 vibrazione = Sport, 2 vibrazioni = Golf |

Mentre Home e 1 sono premuti insieme non arrivano al gioco. Se premi uno dei due un istante prima dell'altro, quel tasto può arrivare al gioco per un attimo.
