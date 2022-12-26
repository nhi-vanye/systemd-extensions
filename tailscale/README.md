Tailscale
=========

See [www.tailscale.com](https://www.tailscale.com) for details,
specifically [What is Tailscale?](https://tailscale.com/kb/1151/what-is-tailscale/)
if you're new to it.

This extension builder supports two authenication keys in /usr/share/tailscale/tailscale
(if /usr is read-only then they can be overriden in/etc/default/tailscale).

The two keys allow separating bootstrapping/remote support during pre-production
by using a reusable, non-pre-authorized key (BOOTSTRAPKEY) and a non-reusable
pre-authorized key (HOSTKEY)

That's the concept behind having two keys, but its up to you to assign
your own attributes to either of them

Installer writers
-----------------

The script is currently being used as part of building a custom
Flatcar Linux installer, where the script is pre-processed before
embedded it in the ISO to allow for easy re-creation of the extension
on an installed system.

If you want to preprocess this script to embed KEYS, then simply
replace these strings (using sed)

- `INSTALLER_BOOTSTRAP_KEY`
- `INSTALLER_HOST_KEY`

i.e.

```shell
sed -i -e "s/INSTALLER_HOST_KEY//g" \
    -e "s/INSTALLER_BOOTSTRAP_KEY/${TAILSCALEBOOTSTRAP}/g" \
    create-tailscale-sysext.sh
```

(really should not be embedded pre-authorized keys into a OS installer)

Helper
------

This extension includes a client-helper script
(`/usr/local/bin/tailscale.sh`) to wrap `tailscale up` and `tailscale
login`) with consistant arguments and the "best" authorization key
available (prefers `HOSTKEY` over `BOOTSTRAPKEY`)

(systemd doesn't support bash paremeter expansion in services, so
using a helper was needed)
