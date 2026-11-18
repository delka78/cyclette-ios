# Cyclette per iPhone — app vera, compilata nel cloud (senza Mac)

L'app viene compilata da **GitHub** su un Mac virtuale (gratis per i repository pubblici), firmata da **Apple nel cloud**
con il tuo account Apple Developer e mandata su **TestFlight**. Tu e la tua ragazza la installate dall'app TestFlight.
Tutto si fa dal browser (PC o iPhone).

L'app contiene la web app di `https://delka78.github.io/` e le dà il Bluetooth: le funzioni sono le stesse,
**gli aggiornamenti della web app continuano a farsi caricando `index.html`** (nessuna nuova compilazione).
La compilazione serve solo la prima volta e poi **ogni 90 giorni** (scadenza delle build TestFlight): un clic.

## Contenuto
| File | A cosa serve |
|---|---|
| `Cyclette/*.swift`, `Cyclette/ble-polyfill.js` | il codice dell'app (Bluetooth, schermata, scelta dispositivo) |
| `Cyclette/Assets.xcassets` | icona |
| `project.yml` | descrive il progetto Xcode (lo genera XcodeGen sul Mac virtuale) |
| `ExportOptions.plist` | come firmare e caricare su TestFlight |
| `.github/workflows/testflight.yml` | il "robot" che compila e carica |

## A. Preparazione su Apple (una volta, dal browser)
1. **Team ID** — developer.apple.com → Account → **Membership details** → copia il *Team ID* (10 caratteri).
2. **Bundle ID** — developer.apple.com → **Certificates, IDs & Profiles** → **Identifiers** → **+** → *App IDs* → *App* →
   Description `Cyclette`, Bundle ID **Explicit** `it.delka78.cyclette` → Continue → Register.
3. **App su App Store Connect** — appstoreconnect.apple.com → **App** → **+** → *Nuova app* → iOS,
   nome a scelta (deve essere unico su tutto l'App Store, es. `Cyclette Delka`; sull'iPhone l'icona si chiamerà comunque "Cyclette"),
   lingua Italiano, Bundle ID `it.delka78.cyclette`, SKU `cyclette`, accesso completo → Crea. Non serve pubblicarla.
4. **Chiave API** — App Store Connect → **Utenti e accessi** → **Integrazioni** → **App Store Connect API** → *Chiavi del team* →
   **+** → nome `GitHub`, accesso **Admin** (con un ruolo inferiore la firma nel cloud fallisce) → Genera.
   - **Scarica la chiave** (file `AuthKey_XXXX.p8`): si può scaricare **una sola volta**, conservala.
   - Annota il **Key ID** (accanto alla chiave) e l'**Issuer ID** (in alto nella pagina).

## B. Repository su GitHub (una volta)
5. github.com → **New repository** → nome `cyclette-ios`, **Public** → Create.
6. **Add file → Upload files** → trascina **tutto il contenuto** di questa cartella (cartelle comprese: `Cyclette`, `.github`,
   `project.yml`, `ExportOptions.plist`, `LEGGIMI.md`) → Commit changes.
   - Se la cartella `.github` non viene caricata: **Add file → Create new file**, scrivi come nome
     `.github/workflows/testflight.yml`, incolla il contenuto del file → Commit.
7. **Settings → Secrets and variables → Actions → New repository secret**, quattro segreti:
   | Nome | Valore |
   |---|---|
   | `APPLE_TEAM_ID` | il Team ID (punto 1) |
   | `ASC_KEY_ID` | il Key ID (punto 4) |
   | `ASC_ISSUER_ID` | l'Issuer ID (punto 4) |
   | `ASC_KEY_P8` | tutto il testo del file `.p8` (aprilo con Blocco note), comprese le righe `-----BEGIN PRIVATE KEY-----` e `-----END PRIVATE KEY-----` |

## C. Compilare e installare
8. Scheda **Actions** → *Cyclette su TestFlight* → **Run workflow** → Run. Dura circa 10–15 minuti; spunta verde = caricata.
   Se diventa rossa: apri il passaggio rosso, copia le ultime righe dell'errore e mandale a Claude.
9. App Store Connect → la tua app → **TestFlight**: la build resta in *Elaborazione* 5–15 minuti.
10. **Tester interni** → **+** → crea un gruppo (es. `Casa`) → aggiungi te stesso.
    Per la tua ragazza: prima **Utenti e accessi → +** (nome, email del suo Apple ID, ruolo *Assistenza clienti*);
    lei accetta l'invito via email; poi aggiungila allo stesso gruppo.
11. Sugli iPhone: installate **TestFlight** dall'App Store, aprite l'invito (email o direttamente in TestFlight) → **Installa**.
    L'icona **Cyclette** compare sulla schermata Home. Al primo avvio consentite il **Bluetooth**.

## D. Portare i dati da Bluefy
12. In **Bluefy**: 📊 → **Dati** → **Esporta** (salva in File o copia il testo).
13. Nell'**app Cyclette**: 📊 → **Dati** → **Importa** (scegli il file o incolla il testo).
    Poi Bluefy si può cancellare.

## E. Dopo
- **Aggiornamenti della Cyclette**: come sempre, nuovo `index.html` su `delka78.github.io` → nell'app compare "Aggiorna".
- **Ogni 90 giorni** TestFlight avvisa che la build scade: GitHub → Actions → **Run workflow** (e in TestFlight → Aggiorna).
- Usa sempre **Run workflow** (non "Re-run"): il numero di build cresce da solo.

## Note tecniche
- Compilazione su `macos-26` con Xcode 26 (Apple accetta su App Store Connect solo build fatte con Xcode 26 o successivi).
- L'archivio viene creato **senza firma** e firmato solo all'esportazione con il certificato di distribuzione gestito da Apple:
  così i Mac virtuali non creano un certificato nuovo a ogni compilazione.
- `ITSAppUsesNonExemptEncryption = NO`: TestFlight non chiede la conformità crittografica.
- Le build sono solo per i **tester interni** (`testFlightInternalTestingOnly`): niente revisione Apple, niente pubblicazione.
- Il Bluetooth funziona solo con la pagina di `delka78.github.io`; per cambiare indirizzo: `AppConfig.url` in `ContentView.swift`.
- Con un Mac si può anche aprire il progetto: `brew install xcodegen && xcodegen generate`, poi aprire `Cyclette.xcodeproj`.
