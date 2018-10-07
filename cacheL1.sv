//`timescale 1ns / 1ps


/*

                                ----------------------COMENTARIOS----------------------
                        
1)
    Esta cache cuando se solicita cargar un bloque, al momento que estoy cargando el ultimo dato que viene de la memoria
    emito el valor solicitado o escribo sobre el valor pedido. Esto quiere decir que se ejecutaria casi de forma instantanea.
     Tiene sus pros y contras como por ejemplo, si requiero el valor de la ultima columna debe esperar que se termine de
    escribir para poder actuar sobre la misma, por lo cual hay que ver si el tiempo es lo suficiente como para poder realizar
    la escritura de L2 a L1 y hacer la proxima accion. La pro es que si no es el ultimo valor de la columna ganaria un ciclo del clock
    
    Se deberia evaluar si vale la pena realizar la accion solicitada en ese momento (estando todavia en el estado WAIT_STORE)
    o esperar y realizar esa acción cuando estas en el estado de READY.
2)
    Cuando hay un dirty en la memoria cache L1 se escribe a las memorias de menor jerarquia cuando la proxima instrucción a 
    ejecutar en L1 no requiere usar el bus de comunicación entre las mismas. Este dato que se envia en el dato mas viejo (modificado)
    ¿Cual es la mejor decisión que se puede optar?
    
3)
    Se esta usando 2 maquinas de estado. Una de ellas es para manejar todo lo que es manejo de datos entre las memorias cache 
    sin el control de WRITEBACK. Lo que corresponde al menejo de datos de WRITEBACK se realiza con otra maquina de estados.
     Esto se hace para simplificar la carga de datos en una sola maquina y que sea mas legible y entendible. Sola hay una señal 
    de la maquina de estados 2 (del WRITEBACK) a la maquina de estados 1, siendo la misma una que le avisa si esta escribiendo o no
    a una memoria de menor jerarquia.
    
*/


module cacheL1 #(parameter N=64,t=52,k=10,b=2,parameter type word= logic [63:0])
    (input logic clk,rst,r_e,w_e,e_r_mem,loadMem,
     input logic [b-1:0] dataPos,
     input logic [N-1:0] addressIn,addressFromMem,dataFromMem,dataFromCPU, //addressFromMem capaz es innecesario, ¡¡¡evaluarlo!!!
     output logic stall,r_L2,w_L2,
     output word instruction,
     output logic [N-1:0] addressOut,dataToMem);
    
     
/*-----Estructura fila de la cache-----*/
typedef struct
{
logic valid;
logic [t-1:0] tag;
logic [b**2-1:0] dirty;
word [2**b-1:0] data;
} filaCache; //1 way

/*-----Creo Cache-----*/
filaCache Way0 [2**k]; //2**k seria el indice (N° de filas)
filaCache Way1 [2**k]; //2**k seria el indice (N° de filas)
logic LRU [2**k];      //Me define cual es la menos reciente usada

/*-----Inicializo Cache-----*/
initial begin
    for(int i=0;i<2**k;i++) begin
        Way0 [i].valid = 0;
        Way1 [i].valid = 0;
        Way0 [i].tag = 0;
        Way1 [i].tag = 0;
        Way0 [i].data = 0;
        Way1 [i].data = 0;
        Way0 [i].dirty= 0;
        Way1 [i].dirty= 0;
        LRU [i] =0;
    end
end 

/*-----Creo señales internas-----*/
logic hit,LRU_aux,dirty_Aux;
logic [k-1:0] indice_Search,indice_Write;
logic [t-1:0] tag_Search,tag_Write,tag_Aux;
logic [b-1:0] columna_Search;
logic [N-1:0] address_to_refresh;
word data_to_write,data_to_refresh;
word [2**b-1:0] data_mux;

/*-----Creo los estados de las 2 maquinas----*/
typedef enum logic [1:0] {Ready,WaitMem,WaitStore,WaitWriteBack} state_t1; 
typedef enum logic {Searching,WaitSending} state_t2;

state_t1 state_reg,state_next;
state_t2 state_reg_2,state_next_2;

/*--------Logica combinacional para señales internas---------*/
assign columna_Search = addressIn[b-1:0];
assign indice_Search = addressIn[(k+b-1):b];
assign tag_Search = addressIn[(t+k+b-1):(k+b)];

always_comb begin
    data_mux[0]='x;
    data_mux[1]='x;
    data_mux[2]='x;
    data_mux[3]='x;
    LRU_aux='x;
    if(Way0[indice_Search].valid)begin
        if(Way0[indice_Search].tag==tag_Search) begin
            hit=1'b1;
            LRU_aux=1'b1;
            data_mux[0]=Way0[indice_Search].data[0];
            data_mux[1]=Way0[indice_Search].data[1];
            data_mux[2]=Way0[indice_Search].data[2];
            data_mux[3]=Way0[indice_Search].data[3];
        end
        else begin
            hit=1'b0;
        end
    end
    else if (Way1[indice_Search].valid) begin
        if(Way1[indice_Search].tag==tag_Search) begin
            hit=1'b1;
            LRU_aux=1'b0;
            data_mux[0]=Way1[indice_Search].data[0];
            data_mux[1]=Way1[indice_Search].data[1];
            data_mux[2]=Way1[indice_Search].data[2];
            data_mux[3]=Way1[indice_Search].data[3];
        end
        else begin
            hit=1'b0;
        end
    end
    else begin
        hit=1'b0;
    end
end

/*--------Machine mealy 1--------*/

//Logica secuencial
always_ff @(posedge clk) begin
    if(rst) 
        state_reg<=Ready;
    else
        state_reg<=state_next;
end
    
//Logica combinacional para analizar cual es el proximo estado
always_comb begin
    case (state_reg)
        Ready:
            if((r_e || w_e) && ~ (hit)) begin //Si quiero leer o escribir y no tengo el dato
                if(dirty_Aux) begin //Si no tengo dirty en la fila
                    state_next=WaitWriteBack;
                end
                else begin
                    state_next=WaitMem;
                end
            end
            else begin
                state_next=Ready;
            end
        WaitMem:
            if(e_r_mem) begin
                state_next=WaitStore;
            end
            else begin
                state_next=WaitMem;
            end        
        WaitWriteBack:
            if(dirty_Aux==0) begin //Antes era (loadMem == 0 && dirty_Aux==0)
                state_next=WaitMem;
            end
            else begin
                state_next=WaitWriteBack;
            end
        WaitStore:
            if(dataPos==2**b-1) begin
                state_next=Ready;
            end
            else begin
                state_next=WaitStore;
            end
        default: begin
            state_next=Ready;
        end
        
    endcase    
end

//logica combinacional para determinar las Señales de control (Sin clock)
always_comb begin
r_L2='x;
w_L2='x;
stall='x;
instruction = 'x;
addressOut='x;
dataToMem='x;
	case (state_reg)
		Ready:	
			if(r_e) begin
				if(hit) begin
                    r_L2=1'b0;
                    w_L2=1'b0;
                    stall=1'b0;
                    instruction = data_mux[columna_Search];
                    LRU[indice_Search]=LRU_aux;//LRU[indice_Search]=LRU_aux;
                end
				else if(dirty_Aux) begin //Si tengo dirty debo enviar para escribir lo nuevo para L2
                    r_L2=1'b0;
                    w_L2=1'b1;
                    stall=1'b1;
                    addressOut=address_to_refresh;
                    dataToMem=data_to_refresh; 
				end
				else begin //quiere decir que el dato no esta
                    r_L2=1'b1;
                    w_L2=1'b0;
                    stall=1'b1;
                    addressOut={tag_Search,indice_Search,2'b00};
                    if(LRU[indice_Search]==0) begin
                        Way0[indice_Search].valid=1'b0;
                    end
                    else begin
                        Way1[indice_Search].valid=1'b0;
                    end
				end
			end
			else if(w_e) begin
				if(hit) begin
                    r_L2=1'b0;
                    w_L2=1'b0;
                    stall=1'b0;
                    if(Way0[indice_Search].tag==tag_Search) begin
                        Way0[indice_Search].data[columna_Search]=data_to_write;
                        Way0[indice_Search].dirty[columna_Search]=1'b1; //Coloco en dirty y en otra maquina de estados veo como escribe en L2
                        LRU[indice_Search]=LRU_aux;//LRU[indice_Search]=LRU_aux;
                    end
                    else begin
                        Way1[indice_Search].data[columna_Search]=data_to_write;
                        Way1[indice_Search].dirty[columna_Search]=1'b1; //Coloco en dirty y otra maquina de estado veo como escribe en L2
                        LRU[indice_Search]=LRU_aux;//LRU[indice_Search]=LRU_aux;
                    end
				end	
				else if(dirty_Aux) begin
                    r_L2=1'b0;
                    w_L2=1'b1;
                    stall=1'b1;
                    addressOut=address_to_refresh;
                    dataToMem=data_to_refresh; 
				end
				else begin
                    r_L2=1'b1;
                    w_L2=1'b0;
                    stall=1'b1;
                    addressOut={tag_Search,indice_Search,2'b00};
                end	
			end
		WaitMem:
            if(r_e||w_e) begin
                r_L2=1'b1;
                w_L2=1'b0;
		        stall=1'b1;
		        addressOut={tag_Search,indice_Search,2'b00}; //Tengo que analizar que pasa en L2 y el offset que le meto
		    end
		WaitWriteBack: //Solo paro CPU y las señales de datos a L2 los setea la otra maquina de estados
            begin
                if(dirty_Aux==0) begin //Significa que termino de enviar todo (antes era loadMem == 0 && dirty_Aux==0)
                    r_L2=1'b1;
                    w_L2=1'b0;
                    stall=1'b1;
                    addressOut={tag_Search,indice_Search,2'b00};//Tengo que analizar que pasa en L2 y el offset que le meto
                end
                else begin
                    r_L2=1'b0;
                    w_L2=1'b1;
                    stall=1'b1;
                    addressOut=address_to_refresh;
                    dataToMem=data_to_refresh;               
                end
            end    
		WaitStore: begin
		    addressOut={tag_Search,indice_Search,2'b00}; //mientras L2 escribe mantengo en el bus la direccion para que no quede don't care
            case(LRU[indice_Search]) //indice_Search deveria ser igual a indice_Write
                0:case(dataPos)
                    0:  begin
                        Way0[indice_Search].dirty[0]=1'b0;
                        Way0[indice_Search].data[0]=dataFromMem;
                        end
                    1:  begin
                        Way0[indice_Search].dirty[1]=1'b0;
                        Way0[indice_Search].data[1]=dataFromMem;
                        end
                    2:  begin
                        Way0[indice_Search].dirty[2]=1'b0;
                        Way0[indice_Search].data[2]=dataFromMem;
                        end
                    3:  begin
                        Way0[indice_Search].dirty[3]=1'b0;
                        Way0[indice_Search].data[3]=dataFromMem;
                        Way0[indice_Search].tag=tag_Search;
                        Way0[indice_Search].valid=1'b1;
                        //LRU[indice_Search]=1'b1;
                        end
                    endcase
                 1:case(dataPos)
                     0:  begin
                         Way1[indice_Search].dirty[0]=1'b0;
                         Way1[indice_Search].data[0]=dataFromMem;
                         end
                     1:  begin
                         Way1[indice_Search].dirty[1]=1'b0;
                         Way1[indice_Search].data[1]=dataFromMem;
                         end
                     2:  begin
                         Way1[indice_Search].dirty[2]=1'b0;
                         Way1[indice_Search].data[2]=dataFromMem;
                         end
                     3:  begin
                         Way1[indice_Search].dirty[3]=1'b0;
                         Way1[indice_Search].data[3]=dataFromMem;
                         Way1[indice_Search].tag=tag_Search;
                         Way1[indice_Search].valid=1'b1;
                         //LRU[indice_Search]=1'b0;
                         end
                     endcase
            endcase
            
            if(dataPos==2**b-1) begin //Significa que es el ultimo dato a grabar
                /*ACA ME FIJO SI YA TENGO EL DATO Y YA LO PONGO EN EL BUS(si r_e) O ESCRIBO EN LA CACHE, ES LO QUE SE HARIA EN EL ESTADO READY*/
                if(hit) begin
                    r_L2=1'b0;
                    w_L2=1'b0;
                    stall=1'b1;//DEJO STALL EN 1 PORQUE SI PONIA EN 0 (QUE YA ME INGRESE OTRA DIRECCION DEL CPU) ME GENERABA METAESTABILIDAD Y EL LRU SE PONIA MAL, CONUSLTAR A FEDE
                    if(r_e) begin
                        instruction = data_mux[columna_Search];
                        LRU[indice_Search]=LRU_aux;//LRU[indice_Search]=LRU_aux;
                    end
                    else if(w_e) begin
                        if(Way0[indice_Search].tag==tag_Search) begin
                            Way0[indice_Search].data[columna_Search]=data_to_write;
                            Way0[indice_Search].dirty[columna_Search]=1'b1; //Coloco en dirty y otra maquina de estado ve cuando escribe en L2
                            LRU[indice_Search]=LRU_aux;
                        end
                        else begin
                            Way1[indice_Search].data[columna_Search]=data_to_write;
                            Way1[indice_Search].dirty[columna_Search]=1'b1; //Coloco en dirty y otra maquina de estado veo como escribe en L2
                            LRU[indice_Search]=LRU_aux;//LRU[indice_Search]=LRU_aux;
                        end
                    end
                end
                else begin //Quiere decir que trajo otra cosa
                    r_L2=1'b1;
                    w_L2=1'b0;
                    stall=1'b1;
                end             
            end
            else if(r_e || w_e) begin
                r_L2=1'b1;
                w_L2=1'b0;
                stall=1'b1;           
            end
        end
	endcase
end

/*--------Machine mealy/moore 2 --------*/


always_ff @(posedge clk) begin
    if(rst) 
        state_reg_2<=Searching;
    else
        state_reg_2<=state_next_2;   
end


always_comb begin
address_to_refresh='x;
    case(state_reg_2)
        Searching:
            if((state_reg==Ready && ~hit) || state_reg==WaitWriteBack) begin //Si tengo que traer un bloque y no tengo hit o estoy en etapa de TX
                if(LRU[indice_Search]==0) begin
                    if(Way0[indice_Search].dirty[0])begin
                        dirty_Aux=1'b1;
                        state_next_2=WaitSending; 
                        Way0[indice_Search].dirty[0]=1'b0;
                        address_to_refresh = {Way0[indice_Search].tag,indice_Search,2'b00};
                        data_to_refresh =Way0[indice_Search].data[0];
                    end
                    else if(Way0[indice_Search].dirty[1])begin
                        dirty_Aux=1'b1;
                        state_next_2=WaitSending; 
                        Way0[indice_Search].dirty[1]=1'b0;   
                        address_to_refresh = {Way0[indice_Search].tag,indice_Search,2'b01};
                        data_to_refresh =Way0[indice_Search].data[1];
                    end
                    else if(Way0[indice_Search].dirty[2])begin
                        dirty_Aux=1'b1;
                        state_next_2=WaitSending;    
                        Way0[indice_Search].dirty[2]=1'b0;
                        address_to_refresh = {Way0[indice_Search].tag,indice_Search,2'b10};
                        data_to_refresh =Way0[indice_Search].data[2];
                    end
                    else if(Way0[indice_Search].dirty[3])begin
                        dirty_Aux=1'b1;
                        state_next_2=WaitSending;  
                        Way0[indice_Search].dirty[3]=1'b0;
                        address_to_refresh = {Way0[indice_Search].tag,indice_Search,2'b11};
                        data_to_refresh =Way0[indice_Search].data[3];  
                    end
                    else begin
                        dirty_Aux=1'b0;
                        state_next_2=Searching;
                    end
                end
                else begin //Significa que el mas viejo es Way1
                    if(Way1[indice_Search].dirty[0])begin
                        dirty_Aux=1'b1;
                        state_next_2=WaitSending;    
                        Way1[indice_Search].dirty[0]=1'b0;
                        address_to_refresh = {Way1[indice_Search].tag,indice_Search,2'b00};
                        data_to_refresh =Way1[indice_Search].data[0];
                    end
                    else if(Way1[indice_Search].dirty[1])begin
                        dirty_Aux=1'b1;
                        state_next_2=WaitSending; 
                        Way1[indice_Search].dirty[1]=1'b0; 
                        address_to_refresh = {Way1[indice_Search].tag,indice_Search,2'b01};
                        data_to_refresh =Way1[indice_Search].data[1]; 
                    end
                    else if(Way1[indice_Search].dirty[2])begin
                        dirty_Aux=1'b1;
                        state_next_2=WaitSending;
                        Way1[indice_Search].dirty[2]=1'b0; 
                        address_to_refresh = {Way1[indice_Search].tag,indice_Search,2'b10};
                        data_to_refresh =Way1[indice_Search].data[2];   
                    end
                    else if(Way1[indice_Search].dirty[3])begin
                        dirty_Aux=1'b1;
                        state_next_2=WaitSending; 
                        Way1[indice_Search].dirty[3]=1'b0;   
                        address_to_refresh = {Way1[indice_Search].tag,indice_Search,2'b11};
                        data_to_refresh =Way1[indice_Search].data[3];
                    end
                    else begin
                        dirty_Aux=1'b0;
                        state_next_2=Searching;
                    end
                end
            end
            else begin
                dirty_Aux=1'b0;
                state_next_2=Searching;          
            end    
        WaitSending:
            if(loadMem) begin //Si la memoria esta cargando el dato que se envio
               state_next_2=WaitSending;
            end
            else begin
               state_next_2=Searching;; 
            end
    endcase
end



endmodule