# 1. Installazione e primo avvio

## Requisiti

- Mac con Apple Silicon, macOS 14 o successivo.
- **SIP disattivato** e **modalità sviluppatore delle estensioni** attiva. Il driver è firmato in locale (senza account sviluppatore Apple) e macOS lo accetta solo così.
  - Controllo: `csrutil status` → *disabled*; `systemextensionsctl developer` → *Developer mode is on*.
  - Per attivare la modalità sviluppatore (con SIP già disattivato): `systemextensionsctl developer on`.
- Bluetooth acceso (Wii Remote, DualSense in Bluetooth).

## Il driver

Il driver (`local.joycon2mac.driver`, DriverKit) è quello che fa comparire nel sistema i controller virtuali: "Joy-Con (L)", "Joy-Con (R)", "Joy-Con 2 Gamepad (Virtual)". Senza driver l'app legge i controller ma nessun gioco li vede.

È **incluso nell'app** (`VirtualJoyCon2.app/Contents/Library/SystemExtensions/`).

- **Primo avvio**: l'app lo installa da sola. Se il driver era già stato installato da JoyCon2Mac, lo sostituisce con la propria copia: da quel momento il driver "appartiene" a VirtualJoyCon2.
- Se macOS chiede l'approvazione compare **Apri Impostazioni**: *Impostazioni di Sistema → Generali → Elementi login ed estensioni → Estensioni driver* → attiva `local.joycon2mac.driver`.
- Se dice che serve il riavvio, riavvia il Mac.
- In qualsiasi momento: **Reinstalla driver** nel riquadro del driver.

Stato nel riquadro in alto:

| Scritta | Significato |
|---|---|
| Driver attivo (installato da VirtualJoyCon2) | Tutto a posto |
| Driver attivo (installato da JoyCon2Mac) | Funziona, ma appartiene ancora a JoyCon2Mac: chiudi JoyCon2Mac e premi *Reinstalla driver* |
| Driver non attivo | Premi *Installa driver*, approva nelle Impostazioni |

> **Chiudi JoyCon2Mac** (app *e* il suo demone `joycon2mac`) prima di usare VirtualJoyCon2: usa lo stesso driver e cerca anche lui i Wii Remote. L'app mostra un avviso arancione finché è aperto. Il demone a volte resta aperto dopo aver chiuso l'app: chiudilo da Monitoraggio Attività (processo `joycon2mac`).

## Compilare l'app

Doppio clic su **Compila.command** (serve Xcode o i Command Line Tools). Lo script:

1. compila il lettore Wii Remote (Objective-C++) e l'app (Swift);
2. copia dentro l'app il driver da `Driver/local.joycon2mac.driver.dext`;
3. firma l'app con il permesso di installare estensioni di sistema (`Sorgenti/VirtualJoyCon2.entitlements`).

Ricompilare non cancella le impostazioni: stanno nelle preferenze di macOS, non nell'app.

## Struttura della cartella

```
VirtualJoyCon2/
├── VirtualJoyCon2.app      l'app (generata da Compila.command)
├── Compila.command         compila l'app
├── Driver/                 driver DriverKit già compilato e firmato
├── Sorgenti/               codice
│   ├── VirtualJoyCon2.swift    app, emulazione Joy-Con, DualSense, interfaccia
│   ├── WiimoteManager.mm       lettura del Wii Remote e del MotionPlus
│   ├── WiiBridge.mm/.h         ponte Objective-C ↔ Swift, 4 posti giocatore
│   ├── WiimotePairer.mm/.h     accoppiamento Bluetooth (tasto SYNC)
│   ├── Info.plist
│   └── VirtualJoyCon2.entitlements
└── docs/                   questa guida
```
