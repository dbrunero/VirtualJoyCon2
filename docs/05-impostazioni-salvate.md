# 5. Cosa viene salvato

Tutto resta tra una sessione e l'altra, anche quando ricompili l'app. Le impostazioni stanno nelle preferenze di macOS del dominio `local.virtualjoycon2.app`.

## Calibrazioni

| Cosa | Chiave | Per chi | Quando si aggiorna |
|---|---|---|---|
| Assi veri (accelerometro e giroscopio) | `axisCal.accel`, `axisCal.gyro` | tutti i telecomandi | *Misura assi…* |
| Sensibilità del giroscopio | `gyroScale.integrato`, `gyroScale.esterno` | per tipo di MotionPlus | *Misura assi…*, *Calibra sensibilità* |
| Zero del giroscopio | `wiiZero.<seriale>.<tipo>` | per singolo telecomando | da solo: a ogni rimisura da fermo e mentre è appoggiato |
| Calibrazione dell'accelerometro | — | — | la legge ogni volta dalla memoria del telecomando |

## Preferenze

| Cosa | Chiave |
|---|---|
| Giocatore: attivo, uscita, lato, impugnatura, vibrazione | `p1.enabled`, `p1.output`, `p1.side`, `p1.sideways`, `p1.rumble` (p1…p4) |
| Profilo attivo e correzioni assi | `p1.profile`, `p1.axisFix` (Sport), `p1.golfAxisFix` (Golf) |
| Posizione al tasto | `p1.aim`, `p1.aimButton` |
| Mappature Wii | `mapping.<classico/joycon2>.<left/right>.<verticale/orizzontale>` |
| DualSense | `ds.enabled`, `ds.mode`, `ds.hide`, `ds.rumble`, `ds.deadzone`, `ds.mapping.<modalità>` |
| Driver già preso in carico | `driver.owned` |

## Ripartire da zero

Con l'app chiusa, da Terminale:

```bash
defaults delete local.virtualjoycon2.app                     # tutto
defaults delete local.virtualjoycon2.app axisCal.accel       # solo gli assi (poi anche axisCal.gyro)
```
