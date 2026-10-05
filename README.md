# Poker Hold'em — version installable sur téléphone

Ce dossier contient l'appli complète, prête à mettre en ligne gratuitement.
Une fois en ligne, toi et tes potes l'ajoutez à l'écran d'accueil : vraie icône,
lancement direct, aucun compte Claude, et ça marche même sans réseau.

Il y a deux étapes. Compte 15 minutes la première fois.

---

## Étape 1 — Supabase (pour jouer ensemble)

C'est ce qui remplace le temps réel que Claude fournissait. Gratuit, sans
limite de durée, et il n'y a aucun serveur à faire tourner.

1. Va sur **supabase.com**, crée un compte (le bouton « Start your project »).
2. Crée un projet. Nom et mot de passe au choix, région **Europe (Frankfurt)**
   ou **Paris** si proposée — plus c'est près, plus c'est fluide.
3. Attends une minute que le projet démarre.
4. Dans le projet : **Settings** (la roue dentée en bas à gauche) → **API**.
5. Recopie deux valeurs dans le fichier **`config.js`** de ce dossier :
   - **Project URL** → `url`
   - la clé **`anon` `public`** → `cle`

Ça doit ressembler à ça :

```js
window.CONFIG_POKER = {
  url: "https://abcdefghijkl.supabase.co",
  cle: "eyJhbGciOiJIUzI1NiIsInR5cCI6..."
};
```

> **La clé `anon` est faite pour être publique**, elle vit normalement dans une
> page web, aucun souci à ce qu'elle soit visible. En revanche ne mets
> **jamais** la clé `service_role` : celle-là donne tous les droits.

Tu n'as rien d'autre à configurer dans Supabase : pas de table à créer, pas de
réglage à changer. L'appli n'utilise que les canaux temps réel, actifs par défaut.

---

## Étape 2 — Mettre en ligne sur GitHub Pages

1. Sur GitHub, crée un dépôt **public**. Appelle-le par exemple `poker`.
2. Dépose **tous les fichiers de ce dossier** à la racine du dépôt
   (bouton « Add file » → « Upload files », tu peux tout glisser d'un coup).
3. Dans le dépôt : **Settings** → **Pages**.
4. Sous « Source », choisis **Deploy from a branch**, branche **main**,
   dossier **/ (root)**. Valide.
5. Attends une à deux minutes. GitHub affiche l'adresse, du type :
   `https://tonpseudo.github.io/poker/`

C'est ton appli. L'adresse ne changera plus.

---

## Étape 3 — L'installer sur les téléphones

Envoie l'adresse à tes potes. Chacun l'ouvre sur son téléphone, puis :

- **iPhone** — ouvrir dans **Safari**, bouton **Partager** (le carré avec la
  flèche), faire défiler, **Sur l'écran d'accueil**.
- **Android** — ouvrir dans **Chrome**, menu **⋮**, **Ajouter à l'écran
  d'accueil** (parfois écrit « Installer l'application »).

L'appli contient aussi un bouton **Installer** sur son écran d'accueil, qui
réaffiche ces étapes — pratique pour ne pas les répéter à chacun.

---

## Vérifier que le multijoueur marche

1. Ouvre l'appli, entre ton nom, **Créer une table**. Un code à 4 lettres s'affiche.
2. Sur un autre téléphone (ou un autre navigateur), ouvre la même adresse,
   **Rejoindre**, tape le code.
3. Vous devez vous voir dans la liste. Lance la partie.

Si les boutons « Créer une table » et « Rejoindre » sont **grisés**, c'est que
`config.js` n'est pas rempli ou que les valeurs sont mauvaises. Touche
« Pourquoi ? » sous le message : l'appli affiche la raison exacte.

---

## Mettre à jour l'appli plus tard

Quand je te donne une nouvelle version :

1. Remplace **`index.html`** dans le dépôt.
2. Ouvre **`sw.js`** et change le numéro de version :
   `const VERSION = 'poker-v1';` → `'poker-v2'`, puis `'poker-v3'`…

Cette deuxième ligne est importante : sans elle, les téléphones qui ont déjà
installé l'appli continueraient d'afficher l'ancienne version depuis leur cache.

---

## Ce qu'il y a dans le dossier

| Fichier | Rôle |
|---|---|
| `index.html` | l'appli entière |
| `config.js` | **les deux valeurs à remplir** |
| `reseau.js` | le temps réel entre joueurs, par-dessus Supabase |
| `supabase.js` | la bibliothèque Supabase, embarquée (aucun CDN à joindre) |
| `sw.js` | permet à l'appli de se lancer sans réseau |
| `manifest.json` | nom et icône une fois installée |
| `icone-*.png`, `apple-touch-icon.png` | les icônes |
| `cotes.html` | la calculatrice de cotes, à ouvrir à côté |
| `construire.py` | regénère `index.html` depuis la version Claude |

---

## Limites à connaître

- **Sans réseau**, l'appli se lance et le solo, l'entraînement, les règles et
  les statistiques marchent. Les tables entre amis, non : elles ont besoin
  d'Internet, forcément.
- **Rien n'est encore conservé** quand on ferme l'appli : nom, avatar, réglages,
  historique et statistiques repartent à zéro. C'est la prochaine chose à faire.
- **Le code de table n'est pas secret.** Quelqu'un qui connaîtrait ton adresse
  et devinerait un code pourrait entrer dans le salon. Entre potes ça n'a pas
  d'importance, mais ne traite pas ça comme privé.
