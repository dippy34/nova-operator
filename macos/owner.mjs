import {Store} from '../core/db.mjs';
import {paths} from '../core/paths.mjs';
const store=new Store(paths.db);
try{
  const id=process.argv[2];
  if(id==='disable')store.db.prepare("DELETE FROM settings WHERE key='computer_owner'").run();
  else{
    if(!store.devices().some(d=>d.id===id))throw new Error('Pass the exact already-paired owner device ID, or disable. See node core/cli.mjs devices.');
    store.db.prepare("INSERT INTO settings(key,value) VALUES('computer_owner',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value").run(id);
  }
  store.event(null,'computer_owner','Computer owner configuration changed locally');
  console.log(id==='disable' ? 'Computer control is disabled.' : 'This paired iPhone now controls the Mac within Nova’s configured access range.');
}finally{store.close();}
