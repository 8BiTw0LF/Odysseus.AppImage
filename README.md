# Odysseus AppImage (med Gear Lever-opdateringer)

Bygger [Odysseus](https://github.com/odysseus-dev/odysseus) som en enkelt AppImage
med indbygget Python. GitHub Actions tjekker upstream hver 6. time og udgiver en
ny release, når der er nye commits. AppImagen har opdateringsinfo indlejret, så
**Gear Lever finder selv nye versioner** – du skal ikke indtaste nogen URL.

## Opsætning (én gang)

1. Opret et nyt **offentligt** repo på GitHub, fx `odysseus-appimage`
   (offentligt, fordi Gear Lever henter releases uden login).
2. Læg filerne fra denne mappe i repoet og push:
   ```bash
   git init && git add . && git commit -m "Odysseus AppImage builder"
   git branch -M main
   git remote add origin git@github.com:<dit-brugernavn>/odysseus-appimage.git
   git push -u origin main
   ```
3. Pushet starter første build automatisk (fanen **Actions**, ca. 5–10 min).
   Herefter kører det selv hver 6. time. Du kan også starte det manuelt under
   *Actions → Build Odysseus AppImage → Run workflow* (sæt `force` for at bygge
   igen uden upstream-ændringer).
4. Hent `Odysseus-…-x86_64.AppImage` fra **Releases** og åbn den med Gear Lever
   → *Unlock* / *Move to the app menu*.

Workflowet bruger `${{ github.repository }}`, så opdateringsinfoen peger
automatisk på dit eget repo – intet skal rettes.

## Sådan opdaterer Gear Lever

AppImagen indeholder
`gh-releases-zsync|<dig>|odysseus-appimage|latest|Odysseus-*-x86_64.AppImage.zsync`.
Gear Lever sammenligner SHA-1 i `.zsync`-filen fra seneste release med din
lokale fil og viser **Update** når de er forskellige.

## Brug

Start fra app-menuen: serveren starter, og din browser åbner
`http://localhost:7000`. Første gang opretter du admin-kontoen i browseren.
Starter du igen mens den kører, åbnes bare browseren.

Højreklik på ikonet → **Stop Odysseus**, eller i en terminal:

```bash
Odysseus.AppImage --stop       # stop serveren
Odysseus.AppImage --status     # kører den?
Odysseus.AppImage --config     # åbn .env (LLM-host, API-nøgler, port …)
Odysseus.AppImage --paths      # vis hvor config/data ligger
Odysseus.AppImage --no-browser # start uden at åbne browser
```

| Hvad    | Hvor                                   |
|---------|----------------------------------------|
| Config  | `~/.config/odysseus/.env`              |
| Data    | `~/.local/share/odysseus/data`         |
| Logs    | `~/.local/share/odysseus/data/logs`    |

Data og config ligger uden for AppImagen og overlever derfor opdateringer.
Port og bind-adresse sættes med `APP_PORT` / `APP_BIND` i `.env` (standard 7000 / 127.0.0.1).

### Bemærk

- ChromaDB (vektorsøgning/RAG) er en separat tjeneste, ligesom ved en almindelig
  native installation. Uden den falder Odysseus tilbage til nøgleordssøgning.
  Kør den fx med `docker run -d -p 8100:8000 chromadb/chroma`.
- `tmux` bruges af Cookbook til baggrundsjobs – installer det via din pakkemanager.
- Virker på x86_64-distroer med glibc ≥ 2.28 (Ubuntu 20.04+, Debian 10+, Fedora 29+ …).

## Byg lokalt

Kræver `git`, `uv`, `curl` og `file`:

```bash
UPDATE_REPO=<dit-brugernavn>/odysseus-appimage ./build-appimage.sh
# → dist/Odysseus-<version>-<commit>-x86_64.AppImage (+ .zsync)
```

## Filer

- `build-appimage.sh` – bygger AppDir (portabel Python 3.12 + requirements + appen) og pakker med appimagetool
- `packaging/AppRun` – indgang i AppImagen
- `packaging/odysseus-launcher.py` – starter/stopper serveren, holder data uden for imaget
- `.github/workflows/build-appimage.yml` – automatisk build + release
