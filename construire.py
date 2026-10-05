#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Fabrique index.html (version hebergee) a partir de poker-v2.html (version Claude).

A relancer apres chaque mise a jour de l'appli :
    python3 construire.py
"""
import re, sys, pathlib

SOURCE = pathlib.Path(__file__).parent.parent / "poker-v2.html"
CIBLE = pathlib.Path(__file__).parent / "index.html"

s = SOURCE.read_text(encoding="utf-8")
avant = len(s)

# --- 1. en-tete : installable, plein ecran, icone ---
a = '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">'
assert a in s, "balise viewport introuvable"
s = s.replace(a, a + """
<link rel="manifest" href="manifest.json">
<meta name="theme-color" content="#0a0708">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Hold'em">
<link rel="apple-touch-icon" href="apple-touch-icon.png">
<link rel="icon" href="icone-192.png">""", 1)

# --- 2. les trois scripts, avant celui de l'appli ---
i = s.index("<script>")
s = s[:i] + ('<script src="supabase.js"></script>\n'
             '<script src="config.js"></script>\n'
             '<script src="reseau.js"></script>\n') + s[i:]

# --- 3. le temps reel passe par Supabase au lieu de Claude ---
a = """async function ensureRoom(){
  if(room)return room;
  try{
    if(typeof claude==='undefined'||!claude.use){raisonNet='page ouverte hors de claude.ai';return null}
    room=await claude.use('room');
    if(!room)raisonNet='accès au temps réel refusé';
  }catch(e){room=null;raisonNet=(e&&e.code)?e.code:'erreur de connexion'}
  return room;
}"""
assert a in s, "ensureRoom introuvable — l'appli a change, adapte ce script"
s = s.replace(a, """async function ensureRoom(){
  if(room)return room;
  try{
    if(typeof SALON_RESEAU!=='function'){raisonNet='fichier reseau.js absent';return null}
    room=await SALON_RESEAU();
    if(!room)raisonNet='Supabase pas encore configuré dans config.js';
  }catch(e){room=null;raisonNet=(e&&e.code)?e.code:'erreur de connexion'}
  return room;
}""", 1)

# --- 4. message d'aide adapte a cette version ---
a = "Les tables entre amis ne sont pas accessibles depuis cette page."
if a in s:
    s = s.replace(a, "Les tables entre amis ne sont pas encore configurées.")

# --- 5. le service worker, pour que l'appli marche sans reseau ---
a = "</body>"
assert a in s
s = s.replace(a, """<script>
if('serviceWorker' in navigator)
  window.addEventListener('load',()=>navigator.serviceWorker.register('sw.js').catch(()=>{}));
</script>
</body>""", 1)

CIBLE.write_text(s, encoding="utf-8")
print("index.html ecrit : %d -> %d caracteres" % (avant, len(s)))
