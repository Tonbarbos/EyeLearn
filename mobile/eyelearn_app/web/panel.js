// Apoio do painel do professor no navegador.
//
// Três coisas que o Dart compilado para JavaScript faria mal ou não faria:
//
// * derivar a chave do cofre pelo PBKDF2 nativo do navegador (WebCrypto),
//   que é dezenas de vezes mais rápido que o mesmo cálculo em JavaScript e
//   não trava a tela;
// * abrir o seletor de arquivos para importar as sessões, vários de uma vez;
// * baixar a cópia de segurança como arquivo.
//
// Nada daqui fala com a rede.
//
// Interface usada pelo Dart (lib/src/teacher/teacher_platform_web.dart):
//   await eyelearnPanel.pbkdf2(Uint8Array senha, Uint8Array sal, iterações)
//       -> Uint8Array(32)
//   await eyelearnPanel.pickFiles(".json") -> [{name, text}]  ([] se cancelar)
//   eyelearnPanel.download(nome, texto, tipo)
//   await eyelearnPanel.persist() -> se o navegador prometeu não apagar
"use strict";

(function () {
  async function pbkdf2(password, salt, iterations) {
    const key = await crypto.subtle.importKey(
      "raw", password, "PBKDF2", false, ["deriveBits"]);
    const bits = await crypto.subtle.deriveBits(
      { name: "PBKDF2", hash: "SHA-256", salt: salt, iterations: iterations },
      key, 256);
    return new Uint8Array(bits);
  }

  function pickFiles(accept) {
    return new Promise((resolve) => {
      const input = document.createElement("input");
      input.type = "file";
      input.multiple = true;
      input.accept = accept;
      input.style.display = "none";
      let settled = false;
      const finish = async () => {
        if (settled) return;
        settled = true;
        const files = Array.from(input.files || []);
        input.remove();
        resolve(await Promise.all(files.map(async (file) => (
          { name: file.name, text: await file.text() }))));
      };
      input.addEventListener("change", finish);
      // Cancelar não dispara "change" em todo navegador.
      input.addEventListener("cancel", finish);
      document.body.appendChild(input);
      input.click();
    });
  }

  function download(name, text, type) {
    const url = URL.createObjectURL(new Blob([text], { type: type }));
    const link = document.createElement("a");
    link.href = url;
    link.download = name;
    document.body.appendChild(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 10000);
  }

  async function persist() {
    try {
      return navigator.storage && navigator.storage.persist
        ? await navigator.storage.persist()
        : false;
    } catch (error) {
      return false;
    }
  }

  window.eyelearnPanel = { pbkdf2, pickFiles, download, persist };
})();
