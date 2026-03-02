# CLAUDE.md - vps-bootstrap

## Projet
Script bash interactif qui securise et prepare un VPS Linux neuf en une seule commande.
Repo public : github.com/mariusdjen/vps-bootstrap

## Conventions

### Git
- Auteur et committer : mariusdjen (mariusdjen@users.noreply.github.com)
- Toujours setter GIT_COMMITTER_NAME et GIT_COMMITTER_EMAIL en plus de --author
- Ne jamais ajouter Claude comme co-auteur
- Messages de commit en francais avec accents
- Tags de version : vX.Y.Z

### Code (setup.sh, deploy.sh, status.sh, backup.sh)
- Pas d'emojis, pas de symboles Unicode
- Indicateurs ASCII : [INFO], [OK], [WARN], [ERR], [>], ===
- Pas de tirets longs (--), utiliser des tirets normaux
- Texte en francais avec accents
- Le script distant est ecrit dans un fichier temporaire (mktemp), envoye par scp, execute par ssh
  - Raison : $(cat << 'EOF' ... EOF) casse avec les case/esac (les ')' des patterns interferent avec le '$(')
- Placeholders dans les scripts distants : __NOM__ remplace par sed avec | comme delimiteur
- Fonction sed_escape() pour echapper les inputs utilisateur avant sed (anti-injection)
- Fonction read_state_var() pour lire le fichier session sans source (anti-execution arbitraire)
- Trap cleanup pour les fichiers temporaires locaux (mktemp)
- Permissions 700 sur les scripts temporaires distants avant execution
- Permissions 600 sur le fichier session local (~/.ssh/.vps-bootstrap-local)

## Architecture du script

### Partie locale (s'execute sur la machine de l'utilisateur)
1. Detection OS local (macOS, Linux, Windows Git Bash, WSL)
2. Choix du mode : nouveau VPS ou mise a jour
3. Selection/creation de cle SSH (fonction select_ssh_key)
4. Demande IP du serveur
5. Mode nouveau : envoi cle sur root, test connexion root
6. Mode update : test connexion user puis root en fallback
7. Sauvegarde session dans ~/.ssh/.vps-bootstrap-local

### Partie distante (s'execute sur le VPS)
Le script distant est genere dans un fichier temp, envoye par scp, execute par ssh.

Detection de la distribution serveur via /etc/os-release :
- Famille debian : Ubuntu, Debian (apt, ufw, sudo group, adduser)
- Famille rhel : AlmaLinux, Rocky, CentOS, Fedora (dnf, firewalld, wheel group, useradd)

Fonctions d'abstraction : pkg_update, pkg_install, sudo_group, create_user, restart_ssh, setup_firewall, setup_caddy, setup_auto_updates, setup_motd

Etapes avec progression (fichier /root/.vps-bootstrap-progress) :
1. Mise a jour systeme + git/curl/wget
2. Creation utilisateur (avec verification si existe deja)
3. Copie cle SSH vers le nouvel utilisateur
4. Durcissement SSH (root desactive, mot de passe desactive)
5. Firewall (ufw ou firewalld, ports 22/80/443)
- Fail2ban (anti-brute-force SSH, marqueur step_fail2ban)
6. Docker (get.docker.com) + rotation des logs (daemon.json max-size 10m)
7. Caddy (apt repo ou copr)
8. Mises a jour automatiques (unattended-upgrades ou dnf-automatic)
9. Dashboard MOTD (etat serveur a chaque connexion SSH)

### Partie post-setup
- Affiche la commande de connexion
- Propose un raccourci SSH dans ~/.ssh/config

## Fichiers
- setup.sh : le script principal de securisation (~800 lignes)
- deploy.sh : script de deploiement d'applications avec rollback (~600 lignes)
- status.sh : affichage de l'etat du VPS et des apps (~200 lignes)
- backup.sh : sauvegarde et restauration des apps (~350 lignes)
- README.md : documentation publique
- LICENSE : MIT, Marius Djen

## Architecture de deploy.sh

### Mode interactif
1. Charge la session vps-bootstrap (~/.ssh/.vps-bootstrap-local)
2. Affiche les 5 derniers deploiements (depuis ~/.deploy-history)
3. Choix : deployer ou revenir en arriere (rollback)
4. Demande : URL depot Git, nom app (suggestion auto), branche/tag, domaine, port, fichier .env
5. Genere un script distant, l'envoie par scp, l'execute par ssh

### Mode CI/CD (non-interactif)
Usage : bash deploy.sh -ip IP -key CLE -user USER -app NOM -repo URL -domain DOMAINE [-port PORT] [-env FICHIER] [-branch BRANCHE] [-tag TAG] [--rollback]
Detection TTY automatique pour compatibilite GitHub Actions.

### Gestion multi-comptes GitHub (sur le VPS)
- Chaque compte GitHub a sa propre cle SSH dans ~/.ssh/github_<label>
- Le fichier ~/.ssh/config route vers la bonne cle via Host github-<label>
- Au premier deploiement : genere la cle, guide l'ajout sur GitHub, teste
- Aux deploiements suivants : liste les comptes existants, l'utilisateur choisit
- L'URL git@github.com: est transformee en github-<label>: pour utiliser la bonne cle

### Etapes du deploiement (distant)
1. Configuration compte GitHub SSH (multi-comptes)
2. Clone ou git pull du depot dans ~/apps/<appname>/
   - Avant git pull : sauvegarde du commit actuel dans .last-working-commit (pour rollback)
3. Installation fichier .env si fourni
4. Detection auto : docker-compose.yml -> docker compose up -d --build, Dockerfile -> docker build + run
5. Configuration Caddy : ajoute le bloc domaine dans /etc/caddy/Caddyfile, valide, recharge
6. Sauvegarde metadonnees : .deploy-domain, .deploy-port, .deploy-branch
7. Historique : ecriture dans ~/.deploy-history (date, app, commit, branche, domaine, action)
8. Nettoyage Docker : docker image prune + docker builder prune apres deploy

### Deploiement de branche/tag
- Arguments -branch BRANCHE et -tag TAG en CI/CD
- Mode interactif : choix branche/tag apres le nom de l'app
- git fetch --all puis git checkout BRANCHE/TAG avant git pull
- Tag = detached HEAD (comportement normal)

### Mode rollback
- Argument --rollback en CI/CD, choix interactif "Revenir en arriere"
- Lit .last-working-commit, fait git checkout, rebuild Docker
- Script distant genere separement du deploiement normal

## Architecture de status.sh

- Meme pattern que deploy.sh : charge session, genere script distant, scp, ssh
- Script distant : infos serveur (OS, uptime, CPU, RAM, disque)
- Scanne ~/apps/*, pour chaque app :
  - docker compose ps ou docker ps pour le status
  - .deploy-domain, .deploy-port pour domaine/port
  - git log -1 pour le dernier commit

## Architecture de backup.sh

### Mode sauvegarde
1. Charge la session vps-bootstrap
2. Choix : une app ou toutes les apps
3. Script distant cree un tar.gz par app dans /tmp contenant :
   - .env (copie directe)
   - Volumes Docker (docker run alpine tar czf)
   - /etc/caddy/Caddyfile
   - metadata.json (app, date, domaine, port, commit)
4. scp recupere les archives en local
5. Nettoyage des fichiers temp sur le VPS

### Mode restauration (--restore)
1. scp envoie le tar.gz sur le VPS
2. Script distant extrait et restaure :
   - .env dans ~/apps/<app>/
   - Volumes Docker (docker run alpine tar xzf)
   - Caddyfile dans /etc/caddy/
   - Metadonnees (.deploy-domain, .deploy-port)
3. Relance les conteneurs Docker

## Historique des versions
- v1.0.0 : Script initial Ubuntu uniquement
- v1.1.0 : Support multi-distribution (Debian + RHEL)
- v1.2.0 : Correction syntaxe heredoc, gestion user existant, dashboard MOTD
- v1.3.0 : Mode nouveau VPS / mise a jour au lancement
- v1.3.1 : Commandes par OS dans le README (macOS, Linux, Git Bash, WSL, PowerShell)
- v2.0.0 : Script deploy.sh avec gestion multi-comptes GitHub SSH sur le VPS
- v2.1.0 : Verification DNS, health check, redirect www, logs erreurs
- v2.2.0 : status.sh, rollback dans deploy.sh, backup.sh
- v2.3.0 : Deploy branche/tag, nettoyage Docker, fail2ban, rotation logs, historique
- v2.3.1 : Corrections securite (sed injection, source, permissions) et bugs (PubkeyAuth, Caddy, backup)
