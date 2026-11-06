import {createClient} from 'npm:@supabase/supabase-js@2.49.8';
import {criarHandler} from './handler.ts';
Deno.serve(criarHandler({createClient,env:(name:string)=>Deno.env.get(name)}));
