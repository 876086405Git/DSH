import z from '@deepseek-ai/schemastery';
export const name='wave10-r6-fixture';
const sample='SYNTHETIC_R6_DEFAULT';
const exceptionMessage='SYNTHETIC_R6_EXCEPTION_VALUE',exceptionPath='SYNTHETIC_R6_EXCEPTION_PATH';
const secret=()=>z.any().role('secret').default(sample);
export const Config=z.object({
 title:z.string().default('fixture'),count:z.number().default(1),live:z.string().default('online').volatile(),
 explicit:secret(),absent:secret(),nil:secret(),empty:secret(),bool:secret(),zero:secret(),equal:secret(),
 structEmpty:z.object({token:z.string().default(sample)}).role('secret'),
 structArray:z.array(z.string()).role('secret'),
 structUnknown:z.object({token:z.string().default(sample)}).role('secret'),
 structNonempty:z.any().role('secret'),
 parent:z.object({secret:z.string().role('secret'),ref:z.string().role('credential-ref').default('R6_DEFAULT_REF')}),
 emptyRef:z.object({secret:z.string().role('secret'),ref:z.string().role('credential-ref').default('R6_DEFAULT_REF')}),
 multiple:z.object({first:secret(),second:secret(),firstRef:z.string().role('credential-ref').default('R6_FIRST_REF'),secondRef:z.string().role('credential-ref').default('R6_SECOND_REF')}),
 composite:z.intersect([z.object({left:z.string().default('left')}),z.object({right:z.string().role('secret').default(sample)})]).default({}),
 rows:z.array(z.object({secret:z.string().role('secret').default(sample)})).default([{}]),
 boundary:z.transform(z.any(),x=>{if(x!=='')throw Error('empty sentinel only');return x;}).default('').role('secret'),
 validation:z.transform(z.number(),x=>{if(x===2)throw new z.ValidationError(exceptionMessage,{path:[exceptionPath]});return x;}).default(0),
});
export function apply(){}
