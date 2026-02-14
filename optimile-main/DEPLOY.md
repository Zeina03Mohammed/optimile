# Deploy Optimile as a public URL

The app runs as **one public URL**: FastAPI serves both the API (`/optimize`) and the Flutter web app (at `/`).

## Option 1: Deploy to Render (recommended)

1. **Build the Flutter web app and add it to the repo** (run from repo root on Windows):
   ```powershell
   .\scripts\build_web_for_deploy.ps1
   git add static/
   git commit -m "Add web build for deploy"
   git push
   ```
   On macOS/Linux, build manually:
   ```bash
   cd flutter_application_1 && flutter pub get && flutter build web && cd ..
   mkdir -p static && cp -r flutter_application_1/build/web/* static/
   git add static/ && git commit -m "Add web build for deploy" && git push
   ```

2. **Connect to Render**
   - Go to [render.com](https://render.com) and sign in (or create an account).
   - **New** → **Web Service**.
   - Connect your Git repo (GitHub/GitLab/Bitbucket).
   - Use these settings:
     - **Root Directory:** leave empty (or the folder that contains `backend.py` and `requirements.txt`).
     - **Runtime:** Python 3  
     - **Build Command:** `pip install -r requirements.txt`  
     - **Start Command:** `uvicorn backend:app --host 0.0.0.0 --port $PORT`

3. **Deploy**
   - Click **Create Web Service**. Render will build and deploy.
   - Your app will be at `https://<your-service-name>.onrender.com`.

4. **Optional:** use the Blueprint instead of manual settings:
   - **New** → **Blueprint** and connect the repo.
   - Render will read `render.yaml` and create the web service with the same build/start commands.

### Notes for Render

- The `static/` folder must exist and contain the Flutter web build (from step 1). If `static/` is missing, only the `/optimize` API will work; the homepage will 404.
- Free tier services spin down after inactivity; the first request after a while may be slow.
- Keep `amazon_delivery.csv` in the repo so the optimizer model can load it at startup.

## Option 2: Run locally and expose with ngrok (quick test)

If you only need a temporary public URL:

1. Build and run the backend with the web app:
   ```powershell
   .\scripts\build_web_for_deploy.ps1
   cd c:\optimiledeploy\optimile-main
   pip install -r requirements.txt
   uvicorn backend:app --host 0.0.0.0 --port 8000
   ```
2. Install [ngrok](https://ngrok.com), then in another terminal:
   ```bash
   ngrok http 8000
   ```
3. Use the `https://....ngrok.io` URL ngrok shows. When you stop ngrok, that URL stops working.

## Local development

- **Backend only:** `uvicorn backend:app --reload --port 8000`
- **Flutter web** (separate port): set `backendBaseUrl = 'http://127.0.0.1:8000'` in `flutter_application_1/lib/map/env.dart`, then `flutter run -d chrome`.
- **Production build (same origin):** leave `backendBaseUrl = ''` in `env.dart` so the app calls `/optimize` on the same host.
