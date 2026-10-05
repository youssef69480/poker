/* ------------------------------------------------------------------
   Temps reel des tables entre amis, par-dessus Supabase Realtime.

   Reproduit exactement l'interface que Claude fournissait a l'appli :

     const salon = await window.SALON_RESEAU();      // null si pas configure
     const table = await salon.join('t-abcd');
     table.peers()        -> [{peer, isMe, sameTab, kind, presence:{...}}]
     table.presence({..}) -> publie mon etat
     table.onPeers(fn)    -> appelee quand la liste change
     table.on(sujet, fn)  -> fn({peer, data, isMe, sameTab})
     table.emit(sujet, d) -> envoie a tous les autres
     table.leave()

   Rien d'autre dans l'appli n'a besoin de changer.
------------------------------------------------------------------ */
(function () {
  "use strict";

  var client = null;

  function config() {
    var c = window.CONFIG_POKER || {};
    var u = (c.url || "").trim().replace(/\/+$/, "");
    var k = (c.cle || "").trim();
    if (!u || !k) return null;
    if (!/^https:\/\/[a-z0-9-]+\.supabase\.co$/i.test(u)) {
      throw { code: "adresse Supabase invalide (attendu https://xxxx.supabase.co)" };
    }
    return { url: u, cle: k };
  }

  /* identifiant unique de cet onglet, le temps de la session */
  var MOI = "p" + Math.random().toString(36).slice(2, 10) + Date.now().toString(36).slice(-4);

  window.SALON_RESEAU = async function () {
    var c = config();
    if (!c) return null;                       /* pas configure : l'appli le dira proprement */
    if (!window.supabase || !window.supabase.createClient) {
      throw { code: "bibliotheque reseau absente" };
    }
    if (!client) {
      client = window.supabase.createClient(c.url, c.cle, {
        auth: { persistSession: false, autoRefreshToken: false },
        realtime: { params: { eventsPerSecond: 40 } }
      });
    }
    return {
      join: function (nom) { return rejoindre(nom); }
    };
  };

  function rejoindre(nom) {
    return new Promise(function (ok, rate) {
      var canal = client.channel(nom, {
        config: {
          presence: { key: MOI },
          broadcast: { self: false, ack: false }
        }
      });

      var ecoutes = {};       /* sujet -> [fn] */
      var surPairs = [];
      var dernier = [];
      var fini = false;

      function listePairs() {
        var etat = {};
        try { etat = canal.presenceState() || {}; } catch (e) { etat = {}; }
        var out = [];
        Object.keys(etat).forEach(function (k) {
          var m = etat[k];
          var dernierEtat = (m && m.length) ? m[m.length - 1] : {};
          out.push({
            peer: k,
            isMe: k === MOI,
            sameTab: k === MOI,
            kind: "viewer",
            presence: {
              n: dernierEtat && dernierEtat.n,
              a: dernierEtat && dernierEtat.a
            }
          });
        });
        /* ordre stable : l'ordre d'arrivee, sinon les sieges danseraient */
        out.sort(function (a, b) {
          var ta = (etat[a.peer] && etat[a.peer][0] && etat[a.peer][0].t) || 0;
          var tb = (etat[b.peer] && etat[b.peer][0] && etat[b.peer][0].t) || 0;
          return ta - tb || (a.peer < b.peer ? -1 : 1);
        });
        return out;
      }

      function prevenirPairs() {
        dernier = listePairs();
        surPairs.forEach(function (f) { try { f(dernier); } catch (e) {} });
      }

      canal.on("presence", { event: "sync" }, prevenirPairs);
      canal.on("presence", { event: "join" }, prevenirPairs);
      canal.on("presence", { event: "leave" }, prevenirPairs);

      canal.on("broadcast", { event: "msg" }, function (ev) {
        var p = (ev && ev.payload) || {};
        var fns = ecoutes[p.s];
        if (!fns || !fns.length) return;
        var m = { peer: p.de, data: p.d, isMe: p.de === MOI, sameTab: p.de === MOI };
        fns.forEach(function (f) { try { f(m); } catch (e) {} });
      });

      var monEtat = { t: Date.now() };

      var minuteur = setTimeout(function () {
        if (fini) return;
        fini = true;
        try { canal.unsubscribe(); } catch (e) {}
        rate({ code: "le serveur temps reel ne repond pas" });
      }, 12000);

      canal.subscribe(function (statut, err) {
        if (fini) return;
        if (statut === "SUBSCRIBED") {
          fini = true; clearTimeout(minuteur);
          canal.track(monEtat).catch(function () {});
          ok({
            peers: function () { return dernier.length ? dernier : listePairs(); },
            presence: function (patch) {
              Object.keys(patch || {}).forEach(function (k) { monEtat[k] = patch[k]; });
              canal.track(monEtat).catch(function () {});
            },
            onPeers: function (f) { surPairs.push(f); try { f(listePairs()); } catch (e) {} },
            on: function (sujet, f) { (ecoutes[sujet] = ecoutes[sujet] || []).push(f); },
            emit: function (sujet, d) {
              canal.send({ type: "broadcast", event: "msg", payload: { s: sujet, de: MOI, d: d } });
            },
            leave: function () {
              try { canal.untrack(); } catch (e) {}
              try { canal.unsubscribe(); } catch (e) {}
            }
          });
        } else if (statut === "CHANNEL_ERROR" || statut === "TIMED_OUT") {
          fini = true; clearTimeout(minuteur);
          try { canal.unsubscribe(); } catch (e) {}
          rate({ code: (err && err.message) ? err.message : "connexion au temps reel refusee" });
        }
      });
    });
  }
})();
