# 8. iPhone come Joy-Con

Senza Wii Remote puoi usare l'**iPhone**: con l'app **VJC Phone** diventa un Joy-Con (L o R) con tasti, stick, giroscopio, accelerometro e vibrazione. Arriva al Mac via **Wi-Fi**, e il Mac lo trova da solo.

## Primo avvio

1. Apri **VirtualJoyCon2.app** sul Mac: nella sezione **iPhone** compare "In ascolto…".
2. Apri **VJC Phone** sull'iPhone, collegato alla **stessa rete Wi-Fi** del Mac.
3. Alla domanda sulla **rete locale** rispondi **Consenti**. Se hai risposto no: Impostazioni → Privacy e sicurezza → Rete locale → VJC Phone.
4. In alto nell'app il pallino diventa **verde** e compare "Il Mac vede: Joy-Con (R)". Sul Mac la riga dell'iPhone mostra i campioni al secondo (circa 100).

## Come si tiene

Come un Wii Remote: **disteso, schermo in su, la parte alta che punta allo schermo**. In questa posizione corrisponde a un Joy-Con impugnato per i giochi di movimento, come il Wii Remote verticale.

## Sull'iPhone

| Elemento | Cosa fa |
|---|---|
| **Sports / Kart** (in alto) | Il setup del gioco (vedi *Setup*). In Sports lo schermo è un Joy-Con destro (A B X Y, R/ZR, +, Home) o sinistro (frecce, L/ZL, −, Cattura); in Kart è la coppia in orizzontale |
| ZR / ZL | Il tasto grande colorato, quello degli swing e dei tiri |
| SL / SR | I tasti sul binario |
| Stick | Trascina dal cerchio; rilasci e torna al centro |
| **Volume +** | ZR (lato R) o ZL (lato L): pressione e rilascio esatti, si può tenere premuto |
| **Volume −** | X (lato R) o freccia su (lato L), per esempio per calibrare il colpo nel golf. Anche il tasto Azione e il Controllo fotocamera fanno lo stesso |
| ⋯ | Scelta del Mac (se ce n'è più di uno), vibrazione ai tasti, tasti volume sì/no, *Inverti Volume + e −* |

Si possono premere più tasti insieme (es. A + ZR). Lo schermo resta acceso finché l'app è aperta.

### Tasti volume e fotocamera

iOS passa i tasti fisici alle app (con pressione **e** rilascio) solo se stanno usando la fotocamera. Per questo VJC Phone tiene accesa la fotocamera frontale al minimo (bassa qualità, 15 fotogrammi al secondo), senza mostrarla né registrare niente: in alto compare il **pallino verde**. In cambio i tasti non cambiano il volume. Alla prima apertura l'app chiede il permesso per la fotocamera; se lo neghi, i tasti volume non funzionano (Impostazioni → VJC Phone → Fotocamera). Se non ti servono, spegnili dal menu ⋯ e la fotocamera si spegne.

### Se l'iPhone si scollega

Se l'app passa in background, lo schermo si blocca o il Wi-Fi cade, il Mac **tiene acceso il Joy-Con per 30 secondi** con i tasti rilasciati. Se l'iPhone torna entro quel tempo, riprende lo stesso Joy-Con: per il gioco il controller non si è mai scollegato e non va in pausa. Il telefono viene riconosciuto da un suo identificativo, non dal nome, perché iOS dà a tutte le app lo stesso nome generico «iPhone».

## Setup

In alto si sceglie il setup: **Sports** o **Kart**. Dal menu ⋯ → *Setup* ci sono anche *Switch Sports (mancino)* e i Joy-Con da soli.

| Setup | Cosa vede il Mac | Come si tiene |
|---|---|---|
| **Switch Sports** | Coppia Joy-Con (L) + (R). L'iPhone è il **destro**, il sinistro c'è ma resta fermo (disteso, senza tasti) | Come un telecomando: disteso, schermo in su, parte alta verso lo schermo |
| **Switch Sports (mancino)** | Come sopra, ma l'iPhone è il **sinistro** e il destro resta fermo | Come sopra |
| **Mario Kart · levetta** | Coppia (L) + (R) a schermo orizzontale: due stick e tutti i tasti. Si sterza con lo **stick sinistro**. Controllo fotocamera (e Volume −) = **derapata (R)**, Volume + = **oggetto (L)** | Come un volante |
| **Mario Kart · giroscopio** | Come sopra, ma si sterza **ruotando il telefono** (stick sinistro dal giroscopio, pieno a 40°; calibra con ⌖ tenendolo dritto). Al centro, per il pollice sinistro, tre pulsanti come su un volante di F1: **DERAPATA** (R, il più grande, tieni), **OGGETTO** (L), **LONTANO** (su + L, es. banane in avanti). Il pollice destro accelera con A. In alto ⓘ apre stato e impostazioni, ⌖ calibra, ✓ apre la verifica. Stessi tasti fisici | Come un volante |
| Joy-Con da solo (L o R) | Un Joy-Con | Per l'emulatore è un controller **in orizzontale** (vedi sotto) |

Perché Sports usa la coppia: Switch Sports accetta solo Joy-Con in coppia (nel log: `supported controller styles 0x6`, cioè portatile + coppia). Con un Joy-Con da solo il gioco non lo prende. Con la coppia invece lo prende, e si gioca con quello in mano, come sulla console.

In Sports, sotto il setup:
- **L | R** sceglie quale Joy-Con è l'iPhone (quello che si muove e ha i tasti).
- **Sport | Golf**: il profilo Golf è come quello dei Wii Remote. Ruota il movimento di 180° attorno alla punta (come «Ruota sulla punta»), perché nel golf il telefono si impugna come una mazza, con la faccia girata dall'altra parte. Da fermo azzera le rotazioni sotto 2 gradi/s, che altrimenti caricano il tiro. Se nel golf la mazza passa accanto alla palla o non la colpisce, è l'orientamento: usa Golf, e torna a Sport per gli altri sport.
- **Tolleranza di X nel golf**: con il profilo Golf, quando premi X (o Volume −; freccia su con il Joy-Con L) l'app misura quanto la punta del telefono è inclinata verso terra. Se è **tra 45° e 90°**, da quel momento il gioco vede il telefono con la punta **dritta in giù**, fino alla pressione successiva (come la «posizione al tasto» dei Wii Remote). Fuori tolleranza X ricalibra normalmente, senza correzione. Sotto i pulsanti l'app scrive l'angolo misurato e se la correzione è stata applicata.
- **Potenza** (1×, 1,5×, 2×, 3×) moltiplica la rotazione e l'accelerazione dello swing; la gravità no, quindi l'inclinazione da fermo resta giusta. Per gli sport veloci 1×. Per il **putter** del golf alza a 2× o 3×: lo swing è lento e corto, e a 1× la palla si muove poco. Con più di 1× la mazza nel gioco ruota più della mano: ricalibra (X, o Volume −) prima di ogni colpo. A 3× gli swing velocissimi vengono tagliati, quindi per tennis e simili torna a 1×.
- Nel menu ⋯, *Sports: muovi anche l'altro Joy-Con* manda il movimento a tutti e due.

Il setup Sports imposta da solo l'uscita **Joy-Con classico** sul Mac. Per Mario Kart l'uscita si sceglie sul Mac, e dipende dall'emulatore del gioco:
- emulatore con i Joy-Con letti direttamente (nel log righe `[jc1]`, come Switch Sports): **Joy-Con classico**, e la coppia diventa un solo giocatore;
- emulatore che prende i Joy-Con da macOS (nel log `fork patches: none`, niente `[jc1]`, come **Mario Kart World**): la coppia classica si spezza in due giocatori (L e R separati). Usa **Joy-Con 2**, un solo controller con due stick e tutti i tasti. Il movimento non serve: con *Sterzo col giroscopio* lo sterzo arriva come stick sinistro. Passare da uno all'altro non cambia il controller per il gioco: la coppia resta la stessa. Fuori da Mario Kart i tasti volume fanno ZR/ZL (Volume +) e X / freccia su (Volume −). Il tasto laterale (blocco schermo) non si può usare: iOS non lo passa alle app.

### Sterzo col giroscopio (Mario Kart · giroscopio)

Nel setup *Mario Kart · giroscopio* ruotando il telefono come un volante (schermo verso di te) l'app muove lo **stick sinistro** a destra e a sinistra: pieno a 40°, 3° di zona morta, dalla sola gravità (gli scossoni non sterzano). Calibra con ⌖ tenendolo dritto. Nel gioco tieni **spenta** la guida con il movimento, altrimenti si sterza due volte.

## Calibrazione (pulsante ⌖ in alto)

Tieni il telefono nella posizione "giusta" e premi **⌖**, oppure *Impostazioni → Calibrazione → Calibra adesso*:
- **Sports** e Joy-Con da soli: disteso, schermo in su, la parte alta verso lo schermo;
- **Mario Kart**: in piedi davanti a te, come un volante dritto.

Da quel momento quella posizione vale come dritta, per il gioco e per lo sterzo col giroscopio. La calibrazione corregge inclinazione e rollio, non la direzione orizzontale: per quella ricentra nel gioco. Si salva a parte per Sports e per Kart; *Azzera calibrazione* la toglie. In alto l'etichetta dice «Calibrato (corretti N°)» o, in arancione, «Non calibrato».

## Tasti fisici su iPhone 17 (mappatura ergonomica)

Provato sul telefono (registro in *Verifica → Tasti fisici*): all'app arrivano solo **due** tasti fisici distinti.
- **Primario**: clic sul Controllo fotocamera e Volume −. Per iOS sono lo stesso tasto; il clic del Controllo fotocamera arriva con pressione e rilascio, quindi si può tenere.
- **Secondario**: Volume +.
- **Non arrivano**: la pressione leggera e lo scorrimento sul Controllo fotocamera (anche con il controllo della fotocamera aggiunto), il tasto Azione e il tasto laterale.

| Setup | Come si tiene | Primario (fotocamera, Volume −) | Volume + |
|---|---|---|---|
| Sports (Joy-Con R) | Mano destra, dita sul bordo sinistro | X, ricalibra | **ZR**, sotto l'indice |
| Sports (Joy-Con L) | Mano sinistra, dita sul bordo destro | **ZL**: il Controllo fotocamera è sotto l'indice | ▲, ricalibra |
| Mario Kart | A volante, parte alta a sinistra | **ZR**, derapata: il Controllo fotocamera è in alto a destra | **ZL**, oggetto |

## Joy-Con classico o Joy-Con 2?

- **Joy-Con classico**: il Mac emula un vero Joy-Con (L) 057E:2006 / (R) 057E:2007 con il protocollo Nintendo. L'emulatore lo legge come un Joy-Con vero, con tasti, stick, movimento, vibrazione e luci, e unisce un sinistro e un destro in una coppia. **Un Joy-Con classico da solo è per l'emulatore un controller tenuto in orizzontale**: tasti e stick ruotano di 90° (B diventa A, giù diventa destra). Per questo con l'iPhone in verticale serve il setup Sports.
- **Joy-Con 2**: il Mac crea il «Joy-Con 2 Gamepad (Virtual)» 057E:2066. Per questo emulatore è un **gamepad generico** (tasti numerati come un 8BitDo): l'orientamento dei tasti sembra giusto, ma non è un Joy-Con e Switch Sports non lo tratta come tale. Per questo «funziona a metà».

Per Switch Sports e Mario Kart: **Joy-Con classico**, con i setup qui sopra.

## Verifica (menu ⋯ → Verifica tasti e movimento)

- **Tasti**: ogni tasto ha due spie. «iPhone» si accende quando il telefono sente il tocco, «Mac» quando il Mac lo riceve: il Mac rimanda all'iPhone i tasti che vede. Premili tutti, tasti volume compresi: devono accendersi tutte e due. Ci sono anche i valori degli stick.
- **Movimento**: cosa legge il telefono, negli assi che arrivano al gioco, più i campioni al secondo che arrivano al Mac (circa 100).
  - Sports (e Joy-Con da soli): alza la punta → «punta in su»; alza il fianco destro → «fianco destro in su»; ruota a sinistra → «gira a SINISTRA».
  - Mario Kart: gira il volante a destra → «volante a destra».
  - Se una frase non corrisponde al movimento, c'è un asse sbagliato: segnalalo.
- Non serve una calibrazione come "Misura assi" del Wii Remote: il giroscopio di iOS è già senza deriva e gli assi dell'iPhone sono documentati. La verifica serve a controllarli.

## Sul Mac (sezione iPhone)

- Fino a **4 iPhone**, ognuno con il proprio controller virtuale (la coppia L+R conta come uno). Una connessione che non si presenta entro 3 secondi (es. una versione vecchia dell'app) non occupa posti.
- **Uscita**: *Joy-Con classico* (L, R o la coppia, secondo il modo scelto sull'iPhone) oppure *Joy-Con 2*.
- **Vibrazione**: le vibrazioni chieste dal gioco arrivano al motore aptico dell'iPhone.
- Le impostazioni si salvano per nome del telefono (`phone.<nome>.output`, `.enabled`, `.rumble`).

## Movimento

- Il giroscopio di iOS è già corretto per la deriva, e gli assi dell'iPhone sono documentati: **non serve "Misura assi"**.
- Campioni a circa 100 al secondo, ognuno con la sua durata vera. Ogni pacchetto ripete gli ultimi 3 campioni: se il Wi-Fi ne perde uno arriva con il successivo; quelli persi del tutto non si inventano.
- Consegna del giroscopio: 90% per report (Joy-Con classico), 50% (Joy-Con 2). I campioni sono più regolari di quelli del Wii Remote.

## Se qualcosa non va

- **Il gioco non lo vede**: per l'emulatore un Joy-Con da solo diventa giocatore **alla prima pressione di un tasto** («press a button to play» nel log). Premi un tasto dopo aver aperto il gioco. Se **cambi lato** (L ↔ R) è un controller nuovo: il vecchio sparisce e bisogna premere di nuovo un tasto. Scegli il lato prima di aprire il gioco.
- **Giochi di movimento**: meglio l'uscita **Joy-Con classico**. L'emulatore legge tasti, stick e movimento dei Joy-Con classici direttamente dai loro report; il «Joy-Con 2 Gamepad (Virtual)» lo prende come un gamepad HID generico (nel log: tasti numerati come un 8BitDo).

- **"Cerco VirtualJoyCon2…" senza fine**: Mac e iPhone sono su reti diverse, oppure è attivo l'isolamento dei client sul router o sulla rete ospiti, oppure manca il permesso Rete locale.
- **Il pallino resta arancione**: il Mac risponde ma il controller virtuale non è attivo. Controlla "Driver attivo" e l'interruttore della riga iPhone.
- **Scatti nel movimento**: con il Wi-Fi a 2,4 GHz affollato arrivano raffiche di pacchetti. Meglio i 5 GHz, o il Mac via cavo sulla stessa rete.

## Compilare l'app iPhone

Progetto: `iPhone/VJCPhone.xcodeproj`. Aprilo in Xcode, collega l'iPhone e premi ▶︎. In alternativa, da Terminale:

```
cd iPhone
xcodebuild -project VJCPhone.xcodeproj -scheme VJCPhone -configuration Release \
  -destination 'id=<UDID iPhone>' -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device <UDID iPhone> build/Build/Products/Release-iphoneos/VJCPhone.app
```

Con un account Apple gratuito l'app scade dopo 7 giorni: basta reinstallarla.

## Codice

- Mac: `Sorgenti/PhoneLink.swift`, con il formato dei pacchetti in cima, `PhoneHub` (Bonjour `_vjc2phone._udp` e UDP) e `PhonePlayer` (riusa `SwitchBridge` / `JoyCon2Output` come il Wii Remote).
- iPhone: `iPhone/VJCPhone/`, cioè `Link.swift` (ricerca e invio), `Motion.swift` (CoreMotion → assi DSU), `Rumble.swift` (Core Haptics), `ControllerView.swift` (interfaccia).
