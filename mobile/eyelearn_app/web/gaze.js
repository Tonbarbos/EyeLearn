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
// Junto dos pontos vão as condições do quadro (Float32Array, NaN quando não
// medida): tamanho da imagem, pose da cabeça, brilho e reflexo na região dos
// olhos e inclinação do celular. O brilho e o reflexo são calculados aqui,
// lendo só um recorte pequeno em volta de cada olho num canvas fora da tela;
// saem dois números, e o recorte é descartado.
//
// Interface usada pelo Dart (lib/src/gaze/platform_gaze_web.dart):
//   eyelearnGaze.onFrame = (segundos, Float32Array de 478*3, condições) => {...}
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
  let frameCount = 0;
  let deviceTilt = NaN;
  let light = { luma: NaN, glare: NaN };
  let probe = null;

  // Ordem das condições, a mesma de _conditions em platform_gaze_web.dart.
  const CONDITIONS = 8;

  function onOrientation(event) {
    deviceTilt = typeof event.beta === "number" ? event.beta : NaN;
  }

  // Rotação da cabeça em graus a partir da matriz de transformação do
  // MediaPipe (4x4, coluna a coluna). Usa a direção para a frente do rosto
  // (terceira coluna) e a lateral (primeira); só o tamanho do ângulo importa,
  // então a convenção de sinais do modelo não interfere.
  function headAngles(m) {
    const fx = m[8], fy = m[9], fz = Math.abs(m[10]);
    const rx = Math.abs(m[0]), ry = m[1];
    const deg = 180 / Math.PI;
    return {
      yaw: Math.atan2(fx, fz) * deg,
      pitch: Math.atan2(fy, fz) * deg,
      roll: Math.atan2(ry, rx) * deg,
    };
  }

  // Brilho médio (0 a 255) e fração de pixels estourados (>= 245) num
  // recorte em volta dos dois olhos, um pouco maior que o olho para pegar o
  // reflexo na lente dos óculos.
  function measureLight(points, width, height) {
    if (!probe) {
      const canvas = document.createElement("canvas");
      canvas.width = 48;
      canvas.height = 24;
      probe = canvas.getContext("2d", { willReadFrequently: true });
    }
    let sum = 0, bright = 0, count = 0;
    for (const [outer, inner] of [[33, 133], [263, 362]]) {
      const a = points[outer], b = points[inner];
      const cx = ((a.x + b.x) / 2) * width;
      const cy = ((a.y + b.y) / 2) * height;
      const w = Math.hypot((a.x - b.x) * width, (a.y - b.y) * height) * 1.6;
      const h = w / 2;
      const sx = Math.max(0, cx - w / 2), sy = Math.max(0, cy - h / 2);
      const sw = Math.min(width - sx, w), sh = Math.min(height - sy, h);
      if (sw < 4 || sh < 2) continue;
      probe.drawImage(video, sx, sy, sw, sh, 0, 0, 48, 24);
      const data = probe.getImageData(0, 0, 48, 24).data;
      for (let i = 0; i < data.length; i += 4) {
        const y = 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2];
        sum += y;
        if (y >= 245) bright++;
        count++;
      }
    }
    return count === 0
      ? { luma: NaN, glare: NaN }
      : { luma: sum / count, glare: bright / count };
  }

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
      outputFacialTransformationMatrixes: true,
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
        // 480x360 e não 640x480: o modelo trabalha num recorte de 192x192
        // do rosto, e um rosto a meio metro já ocupa mais que isso nessa
        // resolução. A mais, só custava tempo por quadro -- e a primeira
        // sessão num celular real saiu a 11 quadros por segundo. Pedir 30
        // por segundo evita que a câmera fique nos 15 que alguns aparelhos
        // usam por padrão.
        video: {
          facingMode: "user",
          width: { ideal: 480 },
          height: { ideal: 360 },
          frameRate: { ideal: 30 },
        },
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
        const width = video.videoWidth, height = video.videoHeight;
        // A luz muda devagar: medir um quadro em cada quatro basta, e poupa
        // o celular mais fraco.
        if (frameCount++ % 4 === 0) {
          try {
            light = measureLight(points, width, height);
          } catch (error) {
            light = { luma: NaN, glare: NaN };
          }
        }
        const matrices = result.facialTransformationMatrixes;
        const pose =
          matrices && matrices.length > 0 && matrices[0].data
            ? headAngles(matrices[0].data)
            : { yaw: NaN, pitch: NaN, roll: NaN };
        const conditions = new Float32Array(CONDITIONS);
        conditions.set([
          width || NaN, height || NaN, pose.yaw, pose.pitch, pose.roll,
          light.luma, light.glare, deviceTilt,
        ]);
        if (typeof window.eyelearnGaze.onFrame === "function") {
          window.eyelearnGaze.onFrame((now - startedAt) / 1000, flat, conditions);
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
    // O Safari do iPhone só toca vídeo que está no documento; invisível. Só
    // os recortes dos olhos passam por um canvas, para medir a luz.
    video.style.cssText =
      "position:fixed;width:1px;height:1px;opacity:0;pointer-events:none;left:0;top:0";
    document.body.appendChild(video);
    video.srcObject = stream;
    await video.play();

    // Inclinação do celular. No Android vem sem pedir; no iPhone exige
    // permissão pedida num toque, e sem ela simplesmente não é medida.
    deviceTilt = NaN;
    try {
      if (typeof DeviceOrientationEvent !== "undefined" &&
          typeof DeviceOrientationEvent.requestPermission === "function") {
        DeviceOrientationEvent.requestPermission().catch(() => {});
      }
    } catch (error) {
      // sem permissão: segue sem a inclinação
    }
    window.addEventListener("deviceorientation", onOrientation);

    startedAt = performance.now();
    lastVideoTime = -1;
    frameCount = 0;
    running = true;
    step();
  }

  function stop() {
    running = false;
    window.removeEventListener("deviceorientation", onOrientation);
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

  window.eyelearnGaze = { start, stop, onFrame: null, headAngles };
})();
