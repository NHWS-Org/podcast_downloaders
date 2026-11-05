# podcast_downloaders

## La Zanzara

`scarica_zanzara.sh` scarica gli episodi elencati nel feed RSS di Radio 24 e
mantiene un archivio locale per non ritentare ogni giorno puntate storiche
che il feed non conferma.

### Download dello script

Per scaricare l'ultima versione:

```sh
wget -O scarica_zanzara.sh https://raw.githubusercontent.com/NHWS-Org/podcast_downloaders/refs/heads/main/scarica_zanzara.sh
chmod +x scarica_zanzara.sh
```

`-O` specifica il nome del file di destinazione: se esiste gia, viene
sovrascritto. Configurare quindi `OUT_DIR` e `START_DATE` nel file scaricato
prima di eseguirlo.

### Requisiti

- Bash (anche la versione 3 fornita da macOS)
- `awk`, per leggere il feed RSS senza dipendenze Python
- GNU `date` (`date` su Linux; `gdate` su macOS, installabile con GNU coreutils)
- `wget`

Impostare `OUT_DIR` e `START_DATE` all'inizio dello script prima di eseguirlo.

### Opzioni

```text
./scarica_zanzara.sh [--dry-run|-n] [--debug|-d] [--repair-gaps]
```

- `--dry-run` simula le operazioni sui file, ma scarica comunque il feed RSS.
- `--debug` abilita il trace Bash e mostra l'output di `wget`.
- `--repair-gaps` ricontrolla gli episodi noti da `START_DATE` a oggi, anno per
  anno, inclusi quelli gia scaricati in precedenza.

La scansione delle cartelle e l'elaborazione procedono per anno. In un terminale,
una riga `[RUN 2026]` aggiorna l'episodio corrente e i contatori di quell'anno.
Prima di passare all'anno successivo viene stampato un riepilogo permanente;
alla fine compare anche il totale di tutti gli anni.
Una riga iniziale permanente annuncia l'avvio prima di qualsiasi comando esterno,
anche durante la scansione degli episodi locali.
Con l'output rediretto restano la riga iniziale e i riepiloghi, senza gli
aggiornamenti di progresso. Errori e avvisi restano messaggi dettagliati su `stderr`.
I riepiloghi includono data e ora e riportano date controllate, episodi scaricati,
gia presenti, non disponibili, errori e download pianificati nel dry-run.
Nella riga compatta: `chk` = date controllate, `D` = scaricate, `OK` = presenti,
`ND` = non disponibili, `E` = errori, `P` = pianificate.
Il programma termina con codice diverso da zero se fallisce un download per un
errore diverso da un episodio non disponibile.

### Archivio storico e pause

Il [feed ufficiale](https://www.radio24.ilsole24ore.com/podcast/lazanzara.xml)
contiene soltanto le puntate recenti, non un calendario completo delle pause.
Lo script mantiene `${OUT_DIR}/zanzara_feed_history.tsv`, un archivio TSV con
data, URL e stato (`1` = scaricata, `0` = presente nel feed ma non ancora
scaricata).

Al primo avvio, dopo aver letto correttamente il feed, importa nell'archivio
le puntate gia presenti nelle cartelle annuali. A ogni esecuzione aggiunge le
voci correnti del feed e aggiorna lo stato dopo i download riusciti. Le puntate
scaricate restano archiviate anche quando escono dalla finestra RSS; le voci non
scaricate vengono conservate solo finche restano nel feed. Cosi' un 404 non
viene ritentato per sempre dopo che Radio 24 rimuove quella puntata dal feed.

Per date fuori dalla finestra corrente, l'archivio conserva quindi solo puntate
gia scaricate. Non vengono piu' indovinati URL per
ogni giorno feriale: cio' evitava di saltare pause estive/natalizie, ma causava
tentativi ripetuti su puntate inesistenti. Nell'intervallo coperto dal feed
ufficiale vengono considerate le date pubblicate, anche in weekend o festivi.
Il contatore `non_disponibili` indica un URL noto che non ha restituito l'audio;
non significa che il programma abbia saltato una puntata certa.

L'archivio viene aggiornato atomicamente e non viene modificato da `--dry-run`.
Per rifare l'importazione iniziale dopo aver verificato un backup, spostare o
rinominare l'archivio esistente prima di una normale esecuzione.

### Test

I test non accedono alla rete e simulano GNU `date` e `wget`. Python e richiesto
soltanto per eseguirli, non per usare lo script su Unraid:

```sh
python3 -m unittest discover -s tests -v
```
