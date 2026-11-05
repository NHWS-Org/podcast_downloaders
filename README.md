# podcast_downloaders

## La Zanzara

`scarica_zanzara.sh` scarica gli episodi mancanti usando il feed RSS di Radio 24
e, per le date anteriori alla copertura del feed, prova gli URL giornalieri.

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
- `--repair-gaps` ricontrolla le date da `START_DATE` fino all'ultimo episodio
  già presente, per recuperare eventuali puntate mancanti nell'intervallo.

In un terminale, il progresso aggiorna una sola riga con l'episodio corrente
e i contatori cumulativi; a fine esecuzione viene stampato un riepilogo.
Con l'output rediretto, le righe di progresso non vengono emesse. Errori e
avvisi restano messaggi dettagliati su `stderr`.
I log includono data e ora. Il riepilogo riporta gli episodi esaminati,
scaricati, già presenti, assenti e falliti.
Il programma termina con codice diverso da zero se fallisce un download per un
errore diverso da un episodio non disponibile.
