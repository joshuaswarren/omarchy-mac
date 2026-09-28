#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"
run_node_test <<'JS'
const fs=require('fs'), os=require('os'), cp=require('child_process')
const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'keyring-'))
try {
  const bin=path.join(tmp,'bin'), log=path.join(tmp,'calls'), list=path.join(tmp,'keyrings'), upgraded=path.join(tmp,'upgraded');fs.mkdirSync(bin)
  function stub(name, body){fs.writeFileSync(path.join(bin,name),'#!/bin/bash\n'+body+'\n',{mode:0o755})}
  // The platform's list is read at a fixed path; the test runs a copy that reads a fixture there.
  const script=path.join(tmp,'omarchy-update-keyring')
  fs.writeFileSync(script,fs.readFileSync(path.join(root,'bin/omarchy-update-keyring'),'utf8').split('/usr/share/omarchy-platform/keyrings').join(list),{mode:0o755})
  stub('sudo','"$@"')
  stub('omarchy-hw-apple-silicon','[[ ${APPLE:-0} == 1 ]]')
  stub('omarchy-pkg-missing','[[ ${MISSING_PACKAGE:-0} == 1 ]]')
  stub('omarchy-pkg-present','[[ " ${INSTALLED:-} " == *" $1 "* ]]')
  stub('pacman-key','echo "key $*" >> "$CALLS"; [[ "$*" != "${FAIL_STEP:-}" ]] || exit 42; if [[ $1 == --list-keys && ${MISSING_KEY:-0} == 1 ]]; then exit 1; fi')
  stub('pacman',`if [[ $1 == -Qlq ]]; then
  [[ \${QL_STATUS:-0} == 0 ]] || exit "$QL_STATUS"
  case $3 in
    archlinux-keyring) printf '%s\\n' /usr/ /usr/share/pacman/keyrings/ /usr/share/pacman/keyrings/archlinux.gpg /usr/share/pacman/keyrings/archlinux-trusted ;;
    archlinuxarm-keyring) printf '%s\\n' /usr/share/pacman/keyrings/archlinuxarm.gpg /usr/share/pacman/keyrings/archlinuxarm-revoked ;;
    asahi-alarm-keyring) if [[ -e \$UPGRADED ]]; then echo /usr/share/pacman/keyrings/asahi-alarm-2.gpg; else echo /usr/share/pacman/keyrings/asahi-alarm.gpg; fi ;;
    empty-keyring) echo /usr/share/doc/empty-keyring/README ;;
    *) exit 1 ;;
  esac
  exit 0
fi
echo "pacman $*" >> "$CALLS"; [[ -z \${RENAME:-} ]] || : > "$UPGRADED"; exit "\${PACMAN_STATUS:-0}"`)
  stub('gpg','echo "pub:::::::::"; echo "fpr:::::::::${FINGERPRINT:-40DFB630FF42BCFFB047046CF0134EE680CAC571}:"')
  const env={...process.env,PATH:bin+':'+process.env.PATH,CALLS:log,UPGRADED:upgraded}
  function run(extra={}, listed=null) {
    fs.writeFileSync(log,'');fs.rmSync(upgraded,{force:true});fs.rmSync(list,{force:true})
    if(listed!==null) fs.writeFileSync(list,listed)
    const result=cp.spawnSync('bash',[script],{env:{...env,...extra},encoding:'utf8'})
    return {...result,log:fs.readFileSync(log,'utf8')}
  }
  const asahiList='# Signing keyrings\n\nasahi-alarm-keyring\n'
  // [Apple Silicon, installed keyrings, the platform's list or null, expected rings]
  const cases=[
    ['0','',null,['archlinux']],
    ['0','asahi-alarm-keyring',null,['archlinux']],
    ['1','',null,['archlinuxarm']],
    ['1','asahi-alarm-keyring',null,['archlinuxarm','asahi-alarm']],
    ['1','asahi-alarm-keyring',asahiList,['archlinuxarm','asahi-alarm']],
    ['1','',asahiList,['archlinuxarm']],
    ['1','archlinuxarm-keyring asahi-alarm-keyring','archlinuxarm-keyring\n'+asahiList,['archlinuxarm','asahi-alarm']],
    ['0','asahi-alarm-keyring','asahi-alarm-keyring',['archlinux','asahi-alarm']],
  ]
  for(const [apple,installed,listed,rings] of cases) {
    const ring=rings.join(' '), packages=rings.map(name=>`${name}-keyring`).join(' ')
    const label=`apple=${apple} installed=[${installed}] list=${listed===null?'none':JSON.stringify(listed)}`
    for(const missing of ['0','1']) {
      const r=run({APPLE:apple,INSTALLED:installed,MISSING_KEY:missing,MISSING_PACKAGE:missing},listed)
      assertEqual(r.status,0,`keyring update succeeds (${label})`+r.stderr)
      assert(r.log.includes(`key --populate ${ring}\n`),`installed trust is restored for every platform ring first (${label})`)
      assert(r.log.includes(`pacman -Sy --noconfirm -- omarchy-keyring ${packages}\n`),`every correct keyring package is refreshed (${label})`)
      assert(r.log.includes(`key --populate omarchy ${ring}\n`),`updated trust and revocations are populated (${label})`)
      assertEqual(r.log.includes('--recv-keys'),missing==='1','bootstrap fetch is limited to missing keys')
    }
    for(const extra of [{PACMAN_STATUS:'42'},{QL_STATUS:'42'},{FAIL_STEP:`--populate ${ring}`},{FAIL_STEP:`--populate omarchy ${ring}`},{FAIL_STEP:'--lsign-key 40DFB630FF42BCFFB047046CF0134EE680CAC571'},{MISSING_KEY:'1',FAIL_STEP:'--recv-keys 40DFB630FF42BCFFB047046CF0134EE680CAC571 --keyserver keys.openpgp.org'}]) {
      const r=run({APPLE:apple,INSTALLED:installed,...extra},listed);assertEqual(r.status,42,`keyring failures propagate (${label} ${JSON.stringify(extra)})`);assert(!r.stdout.includes('Keys are correct'),'failed update never reports success')
    }
  }
  const renamed=run({APPLE:'1',INSTALLED:'asahi-alarm-keyring',RENAME:'1'},asahiList)
  assertEqual(renamed.status,0,'a keyring that renames its ring updates')
  assert(renamed.log.includes('key --populate archlinuxarm asahi-alarm\n')&&renamed.log.includes('key --populate omarchy archlinuxarm asahi-alarm-2\n'),'rings are read again after the reinstall')
  for(const [listed,why] of [['asahi-alarm-keyring; rm -rf /\n','a name with shell syntax'],['../asahi-alarm-keyring\n','a path'],['asahi-alarm\n','a package that is not a keyring'],['-Syu-keyring\n','an option']]) {
    const r=run({APPLE:'1',INSTALLED:'asahi-alarm-keyring'},listed)
    assertEqual(r.status,1,`the platform list may not name ${why}`)
    assert(r.stderr.includes('invalid keyring package')&&!r.log.includes('pacman -Sy'),`${why} is refused before anything changes`)
  }
  const empty=run({APPLE:'1',INSTALLED:'empty-keyring'},'empty-keyring\n')
  assertEqual(empty.status,1,'a listed package that provides no keyring is refused')
  assert(empty.stderr.includes('empty-keyring provides no pacman keyring')&&empty.log==='','nothing runs for a package that provides no keyring')
  const wrong=run({FINGERPRINT:'0000000000000000000000000000000000000000'})
  assertEqual(wrong.status,1,'wrong signing fingerprint is rejected')
  assert(!wrong.log.includes('--lsign-key')&&!wrong.log.includes('pacman -Sy'),'wrong fingerprint cannot be trusted or used to update')
} finally {fs.rmSync(tmp,{recursive:true,force:true})}
JS
