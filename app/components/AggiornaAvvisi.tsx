'use client';
import { useEffect } from 'react';
import { useRouter } from 'next/navigation';
export function AggiornaAvvisi() {
  const router=useRouter();
  useEffect(()=>{
    const timer=setInterval(()=>{
      if(document.visibilityState==='visible'&&!['INPUT','TEXTAREA','SELECT'].includes(document.activeElement?.tagName||''))router.refresh();
    },60000);
    return ()=>clearInterval(timer);
  },[router]);
  return null;
}
