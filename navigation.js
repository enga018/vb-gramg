/* Shared three-dot navigation for VBGRAMG pages. */
(function(){
 function install(){
  var header=document.querySelector('header'); if(!header||document.querySelector('.global-nav')) return;
  var host=document.querySelector('#home-panel .account')||header.querySelector('.app-header-actions, .header-actions, .top-actions, .actions, .account'); if(!host)return;
  header.querySelectorAll('a.menu-link').forEach(function(a){a.remove();});
  var wrap=document.createElement('div');wrap.className='global-nav';
  var button=document.createElement('button');button.type='button';button.className='global-nav-trigger';button.setAttribute('aria-label','Open navigation menu');button.setAttribute('aria-haspopup','true');button.setAttribute('aria-expanded','false');button.title='Navigation';button.textContent='⋮';
  var panel=document.createElement('nav');panel.className='global-nav-panel';panel.setAttribute('aria-label','Main navigation');panel.hidden=true;
  var links=[['Main menu','./'],['MIS','./mis.html'],['Import MIS','./mis-import.html'],['FTO','./fto.html'],['Import FTO','./fto-import.html'],['Work Demand','./demand.html'],['Periods','./periods.html'],['Contribution','./contribution.html']];
  links.forEach(function(item){var a=document.createElement('a');a.href=item[1];a.textContent=item[0];panel.appendChild(a);});
  wrap.appendChild(button);wrap.appendChild(panel);host.appendChild(wrap);
  function close(){panel.hidden=true;button.setAttribute('aria-expanded','false');}
  button.addEventListener('click',function(){var opening=panel.hidden;panel.hidden=!opening;button.setAttribute('aria-expanded',String(opening));});
  document.addEventListener('click',function(e){if(!wrap.contains(e.target))close();});
  document.addEventListener('keydown',function(e){if(e.key==='Escape'){close();button.focus();}});
 }
 if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',install);else install();
})();