// Captura do olhar no navegador: câmera frontal + MediaPipe Face Landmarker.
//
// É o equivalente web de GazePlugin.kt. Entrega ao Dart, por quadro, o
// instante e os 478 pontos do rosto (com as íris), no mesmo formato que o
// canal nativo do Android. Nenhum quadro de imagem sai deste arquivo: o vídeo
// vai direto para o modelo, que roda no próprio aparelho, e só os números
// atravessam para o aplicativo. Nada é enviado pela rede.
//
// O MediaPipe e o modelo vêm do próprio site (pasta mediapipe/, baixada por
// scripts/fetch_mediapipe_web.py), não de CDN de terceiros.
//
// Interface usada pelo Dart (lib/src/gaze/web_gaze_source.dart):
//   eyelearnGaze.onFrame = (segundos, Float32Array de 478*3) => {...}
//   await eyelearnGaze.start()   // rejeita com Error(mensagem para a tela)
//   eyelearnGaze.stop()
"use strict";

(function () {
  const EXPECTED_POINTS = 478;

  let landmarker = null;
  let stream = null;
  let video = null;
  let running = false;
  let startedAt = 0;
  let lastVideoTime = -1;

  function mediapipeUrl(path) {
    return new URL("mediapipe/" + path, document.baseURI).href;
  }

  async function createLandmarker() {
    const vision = await import(mediapipeUrl("vision_bundle.mjs"));
    const fileset = await vision.FilesetResolver.forVisionTasks(mediapipeUrl("wasm"));
    const options = (delegate) => ({
      baseOptions: { modelAssetPath: mediapipeUrl("face_landmarker.task"), delegate },
      runningMode: "VIDEO",
      numFaces: 1,
      outputFaceBlendshapes: false,
      outputFacialTransformationMatrixes: false,
    });
    try {
      return await vision.FaceLandmarker.createFromOptions(fileset, options("GPU"));
    } catch (gpuError) {
      // Alguns Safari e navegadores sem WebGL2 recusam a GPU; a CPU é mais
      // lenta, mas mede o mesmo.
      console.warn("EyeLearn: GPU indisponível, usando CPU", gpuError);
      return await vision.FaceLandmarker.createFromOptions(fileset, options("CPU"));
    }
  }

  async function openCamera() {
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      throw new Error(
        "Este navegador não dá acesso à câmera. Abra o link no Safari ou no " +
          "Chrome, e por https.",
      );
    }
    try {
      return await navigator.mediaDevices.getUserMedia({
        audio: false,
        video: { facingMode: "user", width: { ideal: 640 }, height: { ideal: 480 } },
      });
    } catch (error) {
      if (error && error.name === "NotAllowedError") {
        throw new Error(
          "A câmera foi bloqueada. Permita o acesso à câmera para este site " +
            "nas configurações do navegador e tente de novo.",
        );
      }
      throw new Error("Não foi possível abrir a câmera frontal.");
    }
  }

  function step() {
    if (!running) return;
    const now = performance.now();
    if (video.readyState >= 2 && video.currentTime !== lastVideoTime) {
      lastVideoTime = video.currentTime;
      let result = null;
      try {
        result = landmarker.detectForVideo(video, now);
      } catch (error) {
        console.warn("EyeLearn: quadro perdido", error);
      }
      const faces = result && result.faceLandmarks;
      // Sem rosto, não há quadro: o aplicativo conta a falta como amostra
      // perdida, como no Android.
      if (faces && faces.length > 0 && faces[0].length >= EXPECTED_POINTS) {
        const points = faces[0];
        const flat = new Float32Array(EXPECTED_POINTS * 3);
        for (let i = 0; i < EXPECTED_POINTS; i++) {
          flat[3 * i] = points[i].x;
          flat[3 * i + 1] = points[i].y;
          flat[3 * i + 2] = points[i].z;
        }
        if (typeof window.eyelearnGaze.onFrame === "function") {
          window.eyelearnGaze.onFrame((now - startedAt) / 1000, flat);
        }
      }
    }
    if (video.requestVideoFrameCallback) {
      video.requestVideoFrameCallback(step);
    } else {
      requestAnimationFrame(step);
    }
  }

  async function start() {
    if (running) return;
    if (!landmarker) landmarker = await createLandmarker();
    stream = await openCamera();

    video = document.createElement("video");
    video.setAttribute("playsinline", "");
    video.muted = true;
    video.autoplay = true;
    // O Safari do iPhone só toca vídeo que está no documento; invisível, e
    // nunca desenhado em canvas nenhum.
    video.style.cssText =
      "position:fixed;width:1px;height:1px;opacity:0;pointer-events:none;left:0;top:0";
    document.body.appendChild(video);
    video.srcObject = stream;
    await video.play();

    startedAt = performance.now();
    lastVideoTime = -1;
    running = true;
    step();
  }

  function stop() {
    running = false;
    if (stream) {
      for (const track of stream.getTracks()) track.stop();
      stream = null;
    }
    if (video) {
      video.srcObject = null;
      video.remove();
      video = null;
    }
  }

  window.eyelearnGaze = { start, stop, onFrame: null };
})();
