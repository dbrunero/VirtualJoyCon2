# VirtualJoyCon2

Fa credere al Mac, e quindi agli emulatori Switch come [Switchintosh](https://github.com/dbrunero/switchintosh), che i tuoi controller siano **Joy-Con**, movimento compreso:

- **Wii Remote Plus** (fino a 4, con MotionPlus): giochi di movimento come Switch Sports, golf incluso;
- **DualSense** (PS5), via USB o Bluetooth;
- **iPhone**, con l'app **VJC Phone** (in questo repository): tasti, stick, giroscopio e vibrazione via Wi-Fi, con setup pronti per Switch Sports e Mario Kart.

Ogni controller diventa un **Joy-Con classico** (L, R o la coppia) o un **Joy-Con 2**, grazie a un driver DriverKit incluso nell'app.

## Cosa serve

- Un **Mac con Apple silicon** e **macOS 14** o successivo.
- **SIP disattivato** e **modalità sviluppatore delle estensioni** attiva: il driver è firmato in locale, senza account sviluppatore Apple, e macOS lo accetta solo così.
  - Controllo: `csrutil status` deve dire *disabled*; `systemextensionsctl developer` deve dire *Developer mode is on*.
  - Per attivare la modalità sviluppatore, con SIP già disattivato: `systemextensionsctl developer on`.
  - Disattivare SIP abbassa la protezione del Mac: fallo solo se sai cosa comporta (si fa da Recovery con `csrutil disable`).
- Bluetooth acceso, per Wii Remote e DualSense.

## Installazione

1. Scarica `VirtualJoyCon2-macOS-arm64.zip` dalla pagina [Releases](../../releases/latest), aprilo e trascina **VirtualJoyCon2.app** in Applicazioni.
2. Primo avvio: clic destro → **Apri** (l'app non è firmata da Apple). Se macOS dice che è danneggiata: `xattr -cr /Applications/VirtualJoyCon2.app`.
3. L'app installa da sola il driver. Se macOS chiede l'approvazione: *Impostazioni di Sistema → Generali → Elementi login ed estensioni → Estensioni driver* → attiva `local.joycon2mac.driver`. In alto nell'app deve comparire **«Driver attivo»** in verde.
4. **Wii Remote**: *Accoppia nuovo Wii Remote* e premi il tasto rosso SYNC (solo la prima volta), poi basta 1+2. La prima volta fai **Misura assi…**.
5. **DualSense**: collegalo via USB (consigliato) o Bluetooth.
6. Nell'emulatore assegna i controller: per lui sono Joy-Con (L)/(R) o Joy-Con 2.

La guida completa, in italiano, è in [`docs/`](docs/README.md): Wii Remote, movimento e calibrazioni, DualSense, iPhone, problemi comuni.

## iPhone: VJC Phone

L'app per iPhone si compila da sorgente (`iPhone/VJCPhone.xcodeproj`), perché un'app iOS va firmata con il tuo account Apple:

1. Apri `iPhone/VJCPhone.xcodeproj` in Xcode.
2. In *Signing & Capabilities* scegli il **tuo** Team e cambia il Bundle Identifier (es. `com.tuonome.vjcphone`).
3. Collega l'iPhone e premi ▶︎.

Mac e iPhone sulla stessa rete Wi-Fi: si trovano da soli (Bonjour). Setup, tasti fisici e calibrazione sono in [`docs/08-iphone.md`](docs/08-iphone.md).

## Compilare da sorgente

Serve Xcode (o i Command Line Tools; per l'icona serve Xcode completo).

```
./Compila.command
```

Lo script compila il lettore del Wii Remote (Objective-C++) e l'app (Swift), copia dentro il driver da `Driver/`, compila l'icona (`Icona/AppIcon.icon`) e firma l'app con il permesso di installare estensioni di sistema.

| Cartella | Contenuto |
|---|---|
| `Sorgenti/` | App (Swift: emulazione Joy-Con, DualSense, iPhone, interfaccia), lettore e accoppiamento del Wii Remote (Objective-C++) |
| `Sorgenti/PhoneLink.swift` | Lato Mac dell'iPhone: Bonjour + UDP, formato dei pacchetti in cima al file |
| `iPhone/` | App iOS VJC Phone (SwiftUI) |
| `Driver/` | Driver DriverKit già compilato (sorgente in JoyCon2Mac) |
| `Icona/` | Icona (Icon Composer) |
| `docs/` | Guida |

## Contribuire

Migliorie benvenute:

1. Fai un fork, crea un ramo (`git checkout -b mia-miglioria`).
2. Compila con `./Compila.command` e prova con i controller che hai.
3. Apri una pull request che spiega cosa cambia e come l'hai provato (controller, gioco, emulatore).

Due regole che il codice segue:

- **Assi del Wii Remote:** non scegliere i segni a mano. Si misurano con *Misura assi* (vedi `docs/03-movimento.md` e `docs/06-come-funziona.md`).
- **Movimento:** non inventare rotazione nei buchi del Bluetooth o del Wi-Fi.

Per bug e idee apri una *Issue*.

## Licenza e crediti

MIT, vedi [LICENSE](LICENSE). Il lettore del Wii Remote e il driver vengono da **JoyCon2Mac** (MIT, vedi [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)), che a sua volta ringrazia joycon2cpp, Joy2Win, Switch2-Controllers e Switch2-Mouse.

Non affiliato con Nintendo né con Sony. Nintendo Switch, Joy-Con, Wii Remote, PlayStation e DualSense sono marchi dei rispettivi proprietari.
