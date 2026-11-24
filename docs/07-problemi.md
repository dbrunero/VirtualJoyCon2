# 7. Problemi comuni

| Problema | Cosa fare |
|---|---|
| "Driver non attivo" | *Installa driver*, poi approva in *Impostazioni → Generali → Elementi login ed estensioni → Estensioni driver*. Controlla SIP disattivato e `systemextensionsctl developer on` |
| "Driver attivo (installato da JoyCon2Mac)" | Chiudi JoyCon2Mac **e** il suo demone (`joycon2mac` in Monitoraggio Attività), poi *Reinstalla driver* |
| Avviso arancione JoyCon2Mac / JoyConFinto | Chiudili: usano lo stesso driver e gli stessi controller |
| Il Wii Remote non si collega | Premi 1+2. Se non basta: *Accoppia nuovo Wii Remote* e il tasto SYNC. Guarda `wiimote_pair.log` |
| "MotionPlus non attivo" | Con il Nunchuk collegato il MotionPlus si spegne (il Nunchuk ha la precedenza). Scollega il Nunchuk |
| Movimento al contrario / il gioco ti vede destro quando sei mancino | *Misura assi…* e il controllo finale |
| La mazza deriva o carica da ferma | Profilo **Golf** (Home+1, due vibrazioni). Se continua: *Ricalibra giroscopio* appoggiato a faccia in giù |
| Potenza degli swing incostante | Profilo Golf; tieni il telecomando vicino al Mac (meno campioni Bluetooth persi); prova *Calibra sensibilità* |
| La direzione orizzontale si sposta col tempo | Normale senza Sensor Bar: usa il ricentramento del gioco |
| Il gioco vede sia il DualSense sia il Joy-Con | Attiva *Nascondi il DualSense* |
| L'emulatore non vede niente | Controlla in *Il Mac vede: …* nella finestra del giocatore; nell'emulatore assegna il Joy-Con, non il "Wii Remote" |

## Diagnostica da Terminale

```bash
systemextensionsctl list | grep joycon          # stato del driver
defaults read local.virtualjoycon2.app          # impostazioni e calibrazioni salvate
log show --last 10m --predicate 'process == "sysextd"' | grep -i joycon   # installazione del driver
```
