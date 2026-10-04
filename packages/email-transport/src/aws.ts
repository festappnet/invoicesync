import {sha256,hmacSha256,getSignatureKey} from './aws-sigv4.ts';
export interface AwsEnv{AWS_ACCESS_KEY_ID?:string;AWS_SECRET_ACCESS_KEY?:string;AWS_REGION?:string}
export async function awsRequest(env:AwsEnv,service:'ses'|'sqs'|'sns'|'iam'|'sts',path:string,body:string,transport:typeof fetch=fetch,options:{method?:string;target?:string;contentType?:string}={}){
 if(!env.AWS_ACCESS_KEY_ID||!env.AWS_SECRET_ACCESS_KEY)throw Error('email_transport_not_configured');
 const region=service==='iam'?'us-east-1':env.AWS_REGION??'eu-central-1';if(!/^[a-z]{2}-[a-z]+-\d$/.test(region))throw Error('aws_region');
 const host=service==='iam'?'iam.amazonaws.com':`${service==='ses'?'email':service}.${region}.amazonaws.com`,method=options.method??'POST',contentType=options.contentType??'application/json';
 if(!path.startsWith('/')||path.includes('?')||path.includes('#'))throw Error('aws_path');
 const date=new Date().toISOString().replace(/[-:]/g,'').replace(/\.\d+Z$/,'Z'),stamp=date.slice(0,8),scope=`${stamp}/${region}/${service}/aws4_request`;
 const headers:Record<string,string>={'content-type':contentType,host,'x-amz-date':date};if(options.target)headers['x-amz-target']=options.target;
 const names=Object.keys(headers).sort(),canonical=names.map(k=>`${k}:${headers[k]}\n`).join(''),signed=names.join(';');
 const request=[method,path,'',canonical,signed,await sha256(body)].join('\n'),toSign=['AWS4-HMAC-SHA256',date,scope,await sha256(request)].join('\n');
 const signature=[...new Uint8Array(await hmacSha256(await getSignatureKey(env.AWS_SECRET_ACCESS_KEY,stamp,region,service),toSign))].map(v=>v.toString(16).padStart(2,'0')).join('');
 return transport(`https://${host}${path}`,{method,redirect:'manual',signal:AbortSignal.timeout(15000),headers:{...headers,Authorization:`AWS4-HMAC-SHA256 Credential=${env.AWS_ACCESS_KEY_ID}/${scope}, SignedHeaders=${signed}, Signature=${signature}`},...(method==='GET'?{}:{body})});
}
