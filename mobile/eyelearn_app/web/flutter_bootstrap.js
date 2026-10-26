{{flutter_js}}
{{flutter_build_config}}

// Sem service worker. O padrão do Flutter instala um, que guarda o aplicativo
// e continua servindo a versão antiga depois de cada publicação -- foi assim
// que um painel recém-atualizado gerou link no formato velho. O cache comum
// do navegador já evita baixar tudo de novo a cada visita.
//
// Quem abriu o site antes desta mudança tem o service worker instalado: ele
// é removido aqui, e a página recarrega uma vez para sair do aplicativo que
// ele serviu.
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.getRegistrations().then(function (registrations) {
    if (registrations.length === 0) return;
    Promise.all(registrations.map(function (r) { return r.unregister(); }))
      .then(function () {
        if (!sessionStorage.getItem("eyelearn-sw-removido")) {
          sessionStorage.setItem("eyelearn-sw-removido", "1");
          location.reload();
        }
      });
  });
}

_flutter.loader.load();
