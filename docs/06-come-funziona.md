# 6. Come funziona dentro

## Il percorso di un movimento

```
Wii Remote ──Bluetooth HID──▶ WiimoteManager.mm ──▶ WiiBridge ──▶ WiiPlayer (Swift)
  accelerometro (~100 Hz)        zero, modalità lenta/veloce        correzione assi misurata
  MotionPlus (giroscopio)        assi "DSU"                         profilo, deriva, ricostruzione
                                                                      │
                                     ┌────────────────────────────────┴───────────────┐
                                     ▼                                                ▼
                         SwitchBridge (Joy-Con classico)                   JoyCon2Output (Joy-Con 2)
                         protocollo Nintendo, report 0x30 / 15 ms          report a 200 Hz
                                     └──────────────┬─────────────────────────────────┘
                                                    ▼
                               driver DriverKit local.joycon2mac.driver
                                                    ▼
                         "Joy-Con (L/R)" / "Joy-Con 2" per macOS → SDL → emulatore → gioco
```

## Il Wii Remote

- **Accelerometro**: 3 assi, circa 100 campioni al secondo, scala dalla calibrazione nella memoria del telecomando (indirizzo 0x16).
- **MotionPlus**: giroscopio a 3 assi con due modalità per asse: *lenta* (fino a circa 440°/s, precisa) e *veloce* (fino a circa 2000°/s, negli swing). Nella modalità veloce scala e zero cambiano: la scala viene dalla calibrazione di fabbrica, lo zero si impara ai cambi di modalità.
- **Bluetooth**: i campioni arrivano irregolari e se ne perdono (buchi anche di 80–100 ms). L'app usa la durata vera di ogni intervallo e non inventa mai rotazione nei buchi.

## I Joy-Con

- **Joy-Con classico**: l'app parla il protocollo Nintendo completo (sottocomandi, flash SPI con le calibrazioni, report 0x30 con 3 campioni IMU ogni 15 ms). Per SDL e per gli emulatori è indistinguibile da un Joy-Con vero.
- **Joy-Con 2**: gamepad virtuale con tasti, 2 stick, 2 grilletti e 6 valori di movimento a 200 Hz. Bussola, sensore ottico e NFC del Joy-Con 2 non hanno un campo nel report.
- **Assi**: la conversione tra gli assi del gamepad (+X destra, +Y su, +Z verso il giocatore) e quelli dei Joy-Con è la stessa che usa SDL. Sono solo rotazioni: niente specchi.

## Perché serve "Misura assi"

L'unica conversione che non si può dedurre con certezza dalla documentazione è quella del Wii Remote: i segni degli assi variano tra le fonti e il codice originale li aveva scelti a tentativi. Uno specchio è "coerente", cioè accelerometro e giroscopio vanno d'accordo, quindi a tennis quasi non si nota, ma nel golf e con l'impostazione mancino ribalta tutto. La procedura **misura** il telecomando vero:

- le pose fanno corrispondere ogni asse a una direzione fisica nota;
- il giroscopio si sceglie per coerenza con la gravità: il vettore gravità, visto dal telecomando, ruota come `df/dt = −ω × f`;
- il risultato sono due matrici (permutazioni con segno), applicate a ogni campione prima di tutto il resto (`WiiAxisCalibration.apply`).

## Consegna del giroscopio

Il gioco integra la velocità angolare. L'app accumula l'angolo vero arrivato e a ogni pacchetto ne consegna una quota (60% in Sport, 90% in Golf). Così la velocità non va a strappi, la rotazione totale consegnata è esattamente quella arrivata, e nei buchi Bluetooth non si inventa niente.

## Codice

- `VirtualJoyCon2.swift`: tutto il lato Swift. Cerca i `// MARK:` (Costanti, Client del driver, Installazione del driver, Emulazione del protocollo Joy-Con, DualSense, Motore, interfaccia).
- `WiimoteManager.mm`: lettura del Wii Remote, MotionPlus, zero salvato (`saveGyroBias` / `loadGyroBias`).
- Il driver è già compilato in `Driver/`. Il sorgente sta nel progetto JoyCon2Mac (`VirtualJoyConDriver/`, script `build_driver.sh`).
